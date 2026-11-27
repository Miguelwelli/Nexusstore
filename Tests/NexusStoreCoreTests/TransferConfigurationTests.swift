import Foundation
import XCTest
@testable import NexusStoreCore

/// Verifies that user preferences reach the engine and change its behaviour (temporary files kept or
/// removed, remote-size verification), using the scripted server.
final class TransferConfigurationTests: XCTestCase {

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var finishedJob: TransferJob?
        private let semaphore = DispatchSemaphore(value: 0)

        func record(_ event: TransferEvent) {
            if case .finished(let job) = event {
                lock.lock(); finishedJob = job; lock.unlock()
                semaphore.signal()
            }
        }

        func wait() -> TransferJob? {
            _ = semaphore.wait(timeout: .now() + 15)
            lock.lock(); defer { lock.unlock() }
            return finishedJob
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func job() -> TransferJob {
        TransferJob(
            gameID: UUID(),
            gameName: "Bloodborne",
            coverURLString: "",
            sourceURLString: "https://cdn.example.com/pkg/bloodborne.pkg",
            remoteFileName: "bloodborne.pkg",
            consoleName: "PS4",
            consoleHost: "192.168.1.10",
            consolePort: 2121
        )
    }

    private func controlSocket(sizes: Bool) -> ScriptedSocket {
        var replies = [
            "220 ready\r\n",
            "230 anonymous ok\r\n",
            "215 UNIX Type: L8\r\n",
            "200 Type set to I\r\n",
            "227 Entering Passive Mode (127,0,0,1,196,52)\r\n",
            "150 go\r\n",
            "226 done\r\n"
        ]
        if sizes { replies.append("257 \"/\" is current directory\r\n") }
        return ScriptedSocket(responses: replies)
    }

    func testTemporaryFileIsKeptWhenDeletionIsDisabled() throws {
        let payload = Data(repeating: 0x2A, count: 32 * 1024)
        let networking = FakeNetworking(payload: payload, reportedSize: Int64(payload.count))
        var configuration = TransferConfiguration()
        configuration.deleteLocalFileWhenDone = false
        let engine = TransferEngine(
            workingDirectory: directory,
            networking: networking,
            ftpProvider: ScriptedProvider([controlSocket(sizes: false), ScriptedSocket(responses: [])]),
            configuration: configuration
        )
        let collector = Collector()
        engine.setEventHandler { _, event in collector.record(event) }

        let job = job()
        engine.enqueue(job)
        let finished = try XCTUnwrap(collector.wait())
        XCTAssertEqual(finished.state, .completed, finished.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: engine.localURL(for: job).path),
                      "the .pkg must remain on disk when the setting is off")
    }

    func testUpdateConfigurationAffectsNextJob() throws {
        let payload = Data(repeating: 0x11, count: 16 * 1024)
        let networking = FakeNetworking(payload: payload, reportedSize: Int64(payload.count))
        let engine = TransferEngine(
            workingDirectory: directory,
            networking: networking,
            ftpProvider: ScriptedProvider([controlSocket(sizes: false), ScriptedSocket(responses: [])])
        )
        var configuration = TransferConfiguration()
        configuration.deleteLocalFileWhenDone = false
        engine.updateConfiguration(configuration)

        let collector = Collector()
        engine.setEventHandler { _, event in collector.record(event) }
        let job = job()
        engine.enqueue(job)
        _ = collector.wait()
        XCTAssertTrue(FileManager.default.fileExists(atPath: engine.localURL(for: job).path))
    }

    func testDownloadFailsWhenServerReturnsFewerBytesThanAnnounced() throws {
        let payload = Data(repeating: 0x33, count: 8192)
        // The server claims 100 KB but delivers 8 KB: the engine must not report success.
        let networking = FakeNetworking(payload: payload, reportedSize: 100_000)
        let engine = TransferEngine(
            workingDirectory: directory,
            networking: networking,
            ftpProvider: ScriptedProvider([controlSocket(sizes: false), ScriptedSocket(responses: [])])
        )
        let collector = Collector()
        engine.setEventHandler { _, event in collector.record(event) }
        engine.enqueue(job())
        let finished = try XCTUnwrap(collector.wait())
        XCTAssertEqual(finished.state, .failed)
        XCTAssertFalse(finished.message.isEmpty)
    }

    func testCancellationRemovesPartialDownloadWhenConfigured() throws {
        let payload = Data(repeating: 0x44, count: 4096)
        let networking = FakeNetworking(payload: payload, reportedSize: 4096)
        let engine = TransferEngine(
            workingDirectory: directory,
            networking: networking,
            ftpProvider: ScriptedProvider([controlSocket(sizes: false), ScriptedSocket(responses: [])])
        )
        let collector = Collector()
        engine.setEventHandler { _, event in collector.record(event) }
        let job = job()
        engine.enqueue(job)
        engine.cancelAll()
        _ = collector.wait()
        // Either the job never started (cancelled) or it was cancelled mid-flight; in both cases the
        // temporary file must not be left behind with the default configuration.
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.localURL(for: job).path))
    }
}
