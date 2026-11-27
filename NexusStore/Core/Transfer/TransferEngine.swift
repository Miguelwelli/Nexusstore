import Foundation

/// Events emitted by the engine while a job runs. Delivered **off** the main thread; the app hops to
/// the main actor before touching UI state.
public enum TransferEvent: Sendable {
    case state(TransferJob.State, message: String)
    case downloadProgress(downloaded: Int64, total: Int64)
    case uploadProgress(uploaded: Int64, total: Int64)
    /// Bytes per second measured over a sliding window.
    case speed(bytesPerSecond: Double, remainingSeconds: Double?)
    case finished(TransferJob)
}

/// Result of one transfer attempt.
public struct TransferResult: Sendable {
    public let job: TransferJob
    public let error: FTPError?
    public var succeeded: Bool { error == nil && job.state == .completed }
}

/// Abstraction over the network so the engine's control flow can be tested deterministically and the
/// app can plug in an authenticated, background-capable downloader on iOS.
public protocol TransferNetworking: Sendable {
    /// Downloads `remote` into `destination` (overwriting it is not allowed - the engine handles
    /// resume by passing a destination that already contains partial bytes).
    ///
    /// - Parameters:
    ///   - resumeFromByte: existing file size to continue from (Range header). 0 for a fresh start.
    ///   - progress: (bytesWrittenSoFar including resume offset, totalBytes if known)
    func download(
        from remote: URL,
        to destination: URL,
        resumeFromByte: Int64,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Int64

    func fileSize(for url: URL) -> Int64?
}

/// Sequential transfer queue.
///
/// Design notes:
/// - One job runs at a time. Wi-Fi is a shared resource and the PS4-side FTP servers are usually
///   single-connection, so parallel transfers would only slow each other down.
/// - All state transitions happen on an internal serial queue; the public API is thread-safe.
/// - Pause is only offered while **downloading** (the remote file supports HTTP Range). Once the
///   upload to the console started, the job can only be cancelled — FTP has no portable resume
///   guarantee, and pretending otherwise would risk a corrupt package on the console.
public final class TransferEngine: @unchecked Sendable {

    public typealias EventHandler = @Sendable (UUID, TransferEvent) -> Void

    private let workingDirectory: URL
    private let networking: TransferNetworking
    private let ftpProvider: FTPSocketProvider
    private let configuration: TransferConfiguration
    private let queue = DispatchQueue(label: "com.nexusstore.transfer.engine")
    private let fileManager: FileManager

    private var pendingJobs: [TransferJob] = []
    private var activeJob: TransferJob?
    private var cancelRequested = false
    private var pauseRequested = false
    private var eventHandler: EventHandler?
    private var _currentSpeed: Double = 0
    private var _remainingSeconds: Double?
    private var _phase: TransferPhase = .idle
    private var _startedAt: Date?

    public init(
        workingDirectory: URL,
        networking: TransferNetworking,
        ftpProvider: FTPSocketProvider = BSDFTPSocketProvider(),
        configuration: TransferConfiguration = TransferConfiguration(),
        fileManager: FileManager = .default
    ) {
        self.workingDirectory = workingDirectory
        self.networking = networking
        self.ftpProvider = ftpProvider
        self.configuration = configuration
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    /// Registers the observer used to push UI updates.
    public func setEventHandler(_ handler: @escaping EventHandler) {
        queue.sync { eventHandler = handler }
    }

    public var currentJob: TransferJob? {
        queue.sync { activeJob ?? pendingJobs.first }
    }

    /// Latest measured speed in bytes/second (updated ~every 2 s during upload).
    public var currentSpeed: Double { queue.sync { _currentSpeed } }

    /// Latest remaining-time estimate in seconds.
    public var remainingSeconds: Double? { queue.sync { _remainingSeconds } }

    /// Coarse phase used by the UI to show "Baixando" vs "Transferindo".
    public var phase: TransferPhase { queue.sync { _phase } }

    public var startedAt: Date? { queue.sync { _startedAt } }

    public var queuedCount: Int {
        queue.sync { pendingJobs.count + (activeJob == nil ? 0 : 0) }
    }

    // MARK: - Public API

    /// Adds a job and starts it if the engine is idle.
    public func enqueue(_ job: TransferJob) {
        queue.async { [weak self] in
            guard let self else { return }
            self._currentSpeed = 0
            self._remainingSeconds = nil
            self.pendingJobs.append(job)
            self.emit(job.id, .state(.queued, message: "Na fila de transferência"))
            self.startNextIfIdle()
        }
    }

    /// Requests a cooperative pause (download phase only).
    public func pause() {
        queue.async { [weak self] in
            guard let self, self.activeJob?.state == .downloading else { return }
            self.pauseRequested = true
        }
    }

    /// Cancels the active job (or removes a queued one).
    public func cancel(jobID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.activeJob?.id == jobID {
                self.cancelRequested = true
            } else if let index = self.pendingJobs.firstIndex(where: { $0.id == jobID }) {
                let job = self.pendingJobs.remove(at: index)
                var cancelled = job
                cancelled.state = .cancelled
                cancelled.message = "Removida da fila."
                self.emit(job.id, .finished(cancelled))
            }
        }
    }

    /// Cancels everything and clears the queue (used when the user leaves the PS4 area).
    public func cancelAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelRequested = true
            for job in self.pendingJobs {
                var cancelled = job
                cancelled.state = .cancelled
                cancelled.message = "Fila esvaziada."
                self.emit(job.id, .finished(cancelled))
            }
            self.pendingJobs.removeAll()
        }
    }

    /// Deletes a completed/aborted job's temporary file.
    public func discardTemporaryFile(for job: TransferJob) {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.fileManager.removeItem(at: self.localURL(for: job))
        }
    }

    /// Path of the temporary .pkg for a job (exposed for tests/debug screens).
    public func localURL(for job: TransferJob) -> URL {
        workingDirectory.appendingPathComponent("\(job.id.uuidString).pkg")
    }

    // MARK: - Runner

    private func startNextIfIdle() {
        guard activeJob == nil, let next = pendingJobs.first else { return }
        pendingJobs.removeFirst()
        _currentSpeed = 0
        _remainingSeconds = nil
        _startedAt = Date()
        var job = next
        job.state = .preparing
        job.startedAt = job.startedAt ?? Date()
        activeJob = job
        cancelRequested = false
        pauseRequested = false
        emit(job.id, .state(.preparing, message: "Preparando transferência…"))

        let result = run(job)
        activeJob = nil
        emit(result.job.id, .finished(result.job))
        startNextIfIdle()
    }

    private func run(_ job: TransferJob) -> TransferResult {
        var job = job

        // 1. Validate the source link before touching the network.
        guard let sourceURL = HTTPSURLValidator.url(from: job.sourceURLString) else {
            job.state = .failed
            job.finishedAt = Date()
            job.message = "O link do jogo não é um endereço HTTPS válido. Atualize o cadastro no painel administrativo."
            return TransferResult(job: job, error: .localFile(job.message))
        }

        do {
            // 2. Download (with resume support).
            let localURL = localURL(for: job)
            let existing = Self.fileSize(at: localURL)
            job.state = .downloading
            emit(job.id, .state(.downloading, message: existing > 0 ? "Retomando download…" : "Baixando arquivo PKG…"))
            let total = networking.fileSize(for: sourceURL) ?? job.expectedTotalBytes
            if total > 0, job.expectedTotalBytes != total {
                job.expectedTotalBytes = total
            }
            let downloaded = try networking.download(
                from: sourceURL,
                to: localURL,
                resumeFromByte: existing,
                progress: { [weak self] written, reported in
                    guard let self else { return }
                    let knownTotal = reported > 0 ? reported : max(total, written)
                    job.downloadedBytes = written
                    self.emit(job.id, .downloadProgress(downloaded: written, total: knownTotal))
                },
                isCancelled: { [weak self] in
                    guard let self else { return true }
                    return self.queue.sync { self.cancelRequested || self.pauseRequested }
                }
            )

            if queue.sync(execute: { pauseRequested }) {
                job.downloadedBytes = downloaded
                job.state = .paused
                job.message = "Download pausado (\(ByteFormatting.formatSize(downloaded)) baixados)."
                emit(job.id, .state(.paused, message: job.message))
                return TransferResult(job: job, error: nil)
            }
            if queue.sync(execute: { cancelRequested }) {
                throw FTPError.cancelled
            }

            job.downloadedBytes = downloaded
            if job.expectedTotalBytes > 0, downloaded < job.expectedTotalBytes {
                throw FTPError.closedByServer
            }
            if job.expectedTotalBytes == 0 { job.expectedTotalBytes = downloaded }

            // 3. Upload to the console.
            job.state = .connecting
            emit(job.id, .state(.connecting, message: "Conectando ao console…"))
            let client = FTPClient(provider: ftpProvider)
            try client.connectAndLogin(
                host: job.consoleHost,
                port: job.consolePort,
                user: job.consoleUsername,
                password: "",
                timeout: 20
            )
            if job.remotePath != "/" {
                _ = try? client.changeDirectory(job.remotePath)
            }

            job.state = .transferring
            emit(job.id, .state(.transferring, message: "Enviando para \(job.consoleName)…"))
            let result = try uploadWithMetrics(client: client, job: job, localURL: localURL)

            // 4. Optional verification, only when the server actually implements SIZE.
            if configuration.verifyRemoteSizeWhenAvailable,
               let remoteSize = client.remoteFileSize(job.remoteFileName),
               remoteSize != result {
                throw FTPError.unexpectedReply(
                    command: "SIZE",
                    reply: "o arquivo remoto tem \(remoteSize) bytes, esperado \(result)"
                )
            }
            client.quitSilently()

            job.uploadedBytes = result
            job.state = .completed
            job.finishedAt = Date()
            job.message = "Envio concluído com sucesso."
            emit(job.id, .state(.completed, message: job.message))

            if configuration.deleteLocalFileWhenDone {
                try? fileManager.removeItem(at: localURL)
            }
            return TransferResult(job: job, error: nil)
        } catch let error as FTPError {
            job.finishedAt = Date()
            if error == .cancelled {
                job.state = .cancelled
                job.message = "Transferência cancelada."
                if configuration.cleanTemporaryFilesOnCancel {
                    try? fileManager.removeItem(at: localURL(for: job))
                }
            } else {
                job.state = .failed
                job.message = error.localizedDescription
                if job.uploadedBytes > 0 || job.downloadedBytes == 0 {
                    try? fileManager.removeItem(at: localURL(for: job))
                }
            }
            emit(job.id, .state(job.state, message: job.message))
            return TransferResult(job: job, error: error)
        } catch {
            job.finishedAt = Date()
            job.state = .failed
            job.message = error.localizedDescription
            emit(job.id, .state(.failed, message: job.message))
            return TransferResult(job: job, error: .localFile(error.localizedDescription))
        }
    }

    /// Uploads while measuring speed over a 2-second sliding window.
    private func uploadWithMetrics(client: FTPClient, job: TransferJob, localURL: URL) throws -> Int64 {
        var windowStart = Date()
        var windowBytes: Int64 = 0
        var lastReport = Date.distantPast
        let startedAt = Date()

        return try client.upload(
            fileURL: localURL,
            remoteName: job.remoteFileName,
            progress: { [weak self] sent, total in
                guard let self else { return }
                job.uploadedBytes = sent
                self.emit(job.id, .uploadProgress(uploaded: sent, total: total))
                let now = Date()
                windowBytes = sent
                let elapsed = now.timeIntervalSince(windowStart)
                if elapsed >= 2.0 {
                    let speed = Double(windowBytes) / elapsed
                    let remaining = speed > 0 ? Double(max(total - sent, 0)) / speed : nil
                    self.emit(job.id, .speed(bytesPerSecond: speed, remainingSeconds: remaining))
                    windowStart = now
                    windowBytes = 0
                } else if now.timeIntervalSince(lastReport) > 4.0 {
                    // Always give the UI an average speed even on slow links.
                    let elapsedTotal = now.timeIntervalSince(startedAt)
                    let average = elapsedTotal > 0 ? Double(sent) / elapsedTotal : 0
                    let remaining = average > 0 ? Double(max(total - sent, 0)) / average : nil
                    self.emit(job.id, .speed(bytesPerSecond: average, remainingSeconds: remaining))
                    lastReport = now
                }
            },
            isCancelled: { [weak self] in
                guard let self else { return true }
                return self.queue.sync { self.cancelRequested }
            }
        )
    }

    private func emit(_ id: UUID, _ event: TransferEvent) {
        if case let .speed(bytes, remaining) = event {
            _currentSpeed = bytes
            _remainingSeconds = remaining
        }
        if case let .state(state, _) = event {
            _phase = TransferPhase(state: state)
            if state.isRunning, _startedAt == nil { _startedAt = Date() }
            if state.isTerminal { _startedAt = nil }
        }
        let handler = queue.sync { eventHandler }
        handler?(id, event)
    }

    static func fileSize(at url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
