import Foundation
@testable import NexusStoreCore

/// A deterministic, scripted socket used to exercise the FTP dialogue without a live server.
///
/// - Reads are served from a queue of canned chunks (each `read` call consumes one chunk).
/// - Writes are recorded so tests can assert the exact command sequence.
/// - When the queue is empty, `read` throws `FTPError.timeout` (a real server timeout, not a fake).
final class ScriptedSocket: FTPSocket {
    private var incoming: [Data]
    private(set) var written: [String] = []
    private(set) var isOpen = false
    private(set) var connectCalls: [(String, UInt16)] = []

    init(responses: [String]) {
        self.incoming = responses.map { Data($0.utf8) }
    }

    func connect(host: String, port: UInt16, timeout: TimeInterval) throws {
        connectCalls.append((host, port))
        isOpen = true
    }

    func read(maxLength: Int) throws -> Data? {
        guard isOpen else { throw FTPError.notConnected }
        guard !incoming.isEmpty else { throw FTPError.timeout("scripted socket exhausted") }
        return incoming.removeFirst()
    }

    func write(_ data: Data) throws {
        guard isOpen else { throw FTPError.notConnected }
        written.append(String(decoding: data, as: UTF8.self))
    }

    func close() { isOpen = false }

    /// All commands written so far, trimmed of CRLF.
    var commands: [String] {
        written.map { $0.replacingOccurrences(of: "\r\n", with: "") }
    }
}

/// Provider that hands out pre-built scripted sockets in order.
final class ScriptedProvider: FTPSocketProvider, @unchecked Sendable {
    private var sockets: [ScriptedSocket]
    private(set) var issued: [ScriptedSocket] = []

    init(_ sockets: [ScriptedSocket]) {
        self.sockets = sockets
    }

    func makeSocket() -> FTPSocket {
        guard !sockets.isEmpty else {
            // Falling back to an empty socket makes mistakes visible as timeouts instead of crashes.
            return ScriptedSocket(responses: [])
        }
        let socket = sockets.removeFirst()
        issued.append(socket)
        return socket
    }
}

/// Downloader double. Writes `payload` to the destination and reports one progress update per chunk.
final class FakeNetworking: TransferNetworking, @unchecked Sendable {
    var payload: Data
    var reportedSize: Int64?
    var failWith: Error?
    var chunkSize = 8
    /// Delay inserted before each chunk; lets tests observe a running job deterministically.
    var chunkDelay: TimeInterval = 0
    var downloads: [(URL, Int64)] = []

    init(payload: Data, reportedSize: Int64? = nil) {
        self.payload = payload
        self.reportedSize = reportedSize
    }

    func fileSize(for url: URL) -> Int64? { reportedSize }

    func download(
        from remote: URL,
        to destination: URL,
        resumeFromByte: Int64,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Int64 {
        downloads.append((remote, resumeFromByte))
        if let failWith { throw failWith }

        var existing = Data()
        if resumeFromByte > 0, let handle = try? FileHandle(forReadingFrom: destination) {
            existing = (try? handle.readToEnd()) ?? Data()
            try? handle.close()
            if existing.count > Int(payload.count) { existing = existing.prefix(Int(payload.count)) }
        }
        let remaining = payload.dropFirst(min(existing.count, payload.count))
        var output = existing
        var offset = Int64(output.count)
        let total = Int64(payload.count)
        var index = remaining.startIndex
        while index < remaining.endIndex {
            if isCancelled() { throw FTPError.cancelled }
            if chunkDelay > 0 { Thread.sleep(forTimeInterval: chunkDelay) }
            let end = remaining.index(index, offsetBy: chunkSize, limitedBy: remaining.endIndex) ?? remaining.endIndex
            output.append(contentsOf: remaining[index..<end])
            index = end
            offset += Int64(remaining.distance(from: end, to: end))
            offset = Int64(output.count)
            progress(offset, total)
        }
        if output.isEmpty && payload.isEmpty {
            output = Data()
        }
        try output.write(to: destination)
        return Int64(output.count)
    }
}
