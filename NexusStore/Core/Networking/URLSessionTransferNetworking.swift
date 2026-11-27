import Foundation

/// Streaming HTTPS downloader used by the transfer engine.
///
/// - Writes to disk in 256 KiB chunks (`FileHandle`) — a 100 GB package never sits in memory.
/// - Supports HTTP resume (`Range: bytes=N-`) and validates the `206 Partial Content` answer, falling
///   back to a clean restart when the server ignores the range (otherwise the file would be corrupt).
/// - Reports progress through the callback; cancellation is cooperative and checked per chunk.
/// - Requests disk space up front when the server advertises `Content-Length`, failing with a clear
///   message instead of crashing mid-transfer when the iPhone is full.
public final class URLSessionTransferNetworking: TransferNetworking, @unchecked Sendable {

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60 * 60 * 12
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    public func fileSize(for url: URL) -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        let semaphore = DispatchSemaphore(value: 0)
        var size: Int64?
        let task = session.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse,
               let length = http.value(forHTTPHeaderField: "Content-Length"),
               let value = Int64(length), value > 0 {
                size = value
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return size
    }

    public func download(
        from remote: URL,
        to destination: URL,
        resumeFromByte: Int64,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Int64 {
        var resumeOffset = resumeFromByte
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try streamDownload(
                    from: remote,
                    to: destination,
                    resumeOffset: resumeOffset,
                    progress: progress,
                    isCancelled: isCancelled
                )
            } catch let error as DownloadError where error == .serverIgnoredRange && attempt == 1 {
                // Server does not support Range: restart from scratch.
                try? FileManager.default.removeItem(at: destination)
                resumeOffset = 0
                continue
            }
        }
    }

    enum DownloadError: Error, Equatable {
        case serverIgnoredRange
        case httpStatus(Int)
        case diskSpace(String)
        case write(String)
    }

    private func streamDownload(
        from remote: URL,
        to destination: URL,
        resumeOffset: Int64,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Int64 {
        var request = URLRequest(url: remote)
        request.timeoutInterval = 60
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let stateQueue = DispatchQueue(label: "com.nexusstore.download.state")
        var thrown: Error?
        var finalSize: Int64 = 0
        var finished = false

        let task = session.dataTask(with: request) { data, response, error in
            defer {
                stateQueue.sync { finished = true }
                semaphore.signal()
            }
            if let error {
                stateQueue.sync { thrown = error }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                stateQueue.sync { thrown = DownloadError.httpStatus(-1) }
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                stateQueue.sync { thrown = DownloadError.httpStatus(http.statusCode) }
                return
            }
            let isPartial = http.statusCode == 206
            if resumeOffset > 0 && !isPartial {
                stateQueue.sync { thrown = DownloadError.serverIgnoredRange }
                return
            }
            let contentLength = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
            let total = contentLength + (isPartial ? resumeOffset : 0)

            // Reserve disk space up front when we know the size.
            if total > 0, isPartial == false || resumeOffset == 0 {
                if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: destination.deletingLastPathComponent().path),
                   let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
                   free < contentLength + 64 * 1024 * 1024 {
                    stateQueue.sync {
                        thrown = DownloadError.diskSpace("Espaço insuficiente no iPhone para baixar \(ByteFormatting.formatSize(contentLength)).")
                    }
                    return
                }
            }

            let handle: FileHandle
            do {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    FileManager.default.createFile(atPath: destination.path, contents: nil)
                }
                handle = try FileHandle(forWritingTo: destination)
                if isPartial {
                    try handle.seekToEnd()
                } else {
                    try handle.truncate(atOffset: 0)
                }
            } catch {
                stateQueue.sync { thrown = DownloadError.write(error.localizedDescription) }
                return
            }
            defer { try? handle.close() }

            var written = resumeOffset
            var buffer = Data()
            buffer.reserveCapacity(512 * 1024)
            // `data` is delivered in chunks by URLSession; flush in ~256 KiB blocks so memory use is
            // bounded even for very large packages.
            var chunkIndex = 0
            write: for byte in data ?? Data() {
                if isCancelled() {
                    stateQueue.sync { thrown = FTPError.cancelled }
                    task.cancel()
                    return
                }
                buffer.append(byte)
                chunkIndex += 1
                if buffer.count >= 256 * 1024 {
                    do { try handle.write(contentsOf: buffer) } catch {
                        stateQueue.sync { thrown = DownloadError.write(error.localizedDescription) }
                        return
                    }
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(written, total)
                }
            }
            if !buffer.isEmpty {
                do { try handle.write(contentsOf: buffer) } catch {
                    stateQueue.sync { thrown = DownloadError.write(error.localizedDescription) }
                    return
                }
                written += Int64(buffer.count)
                progress(written, total)
            }
            stateQueue.sync { finalSize = written }
        }

        task.resume()
        // Wait for the request to finish; poll cancellation so a cancel is noticed even while the
        // server is silent.
        while semaphore.wait(timeout: .now() + 0.5) == .timedOut {
            let done = stateQueue.sync { finished }
            if isCancelled() && !done {
                task.cancel()
            }
            if done { break }
        }

        var outcome: Error?
        var size: Int64 = 0
        stateQueue.sync {
            outcome = thrown
            size = finalSize
            if size == 0 { size = Self.localSize(destination) }
        }
        if let outcome { throw outcome }
        return size
    }

    private static func localSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
