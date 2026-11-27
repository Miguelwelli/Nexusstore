import XCTest
@testable import NexusStoreCore

/// Collects engine events with a lock and lets tests wait for a terminal state.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [(UUID, TransferEvent)] = []
    private let finished = DispatchSemaphore(value: 0)

    func record(_ id: UUID, _ event: TransferEvent) {
        lock.lock()
        events.append((id, event))
        lock.unlock()
        if case .finished = event { finished.signal() }
    }

    func wait(timeout: TimeInterval = 15) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }

    var lastFinishedJob: TransferJob? {
        lock.lock(); defer { lock.unlock() }
        for (_, event) in events.reversed() {
            if case .finished(let job) = event { return job }
        }
        return nil
    }

    var states: [TransferJob.State] {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap { _, event in
            if case .state(let state, _) = event { return state }
            return nil
        }
    }
}

final class TransferEngineTests: XCTestCase {

    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func makeJob(source: String = "https://cdn.example.com/pkg/game.pkg") -> TransferJob {
        TransferJob(
            gameID: UUID(),
            gameName: "God of War Ragnarök",
            coverURLString: "",
            sourceURLString: source,
            remoteFileName: "god-of-war-ragnarok.pkg",
            consoleName: "PS4 PRO - SALA",
            consoleHost: "192.168.1.104",
            consolePort: 2121,
            expectedTotalBytes: 0
        )
    }

    func testInvalidSourceLinkFailsBeforeAnyNetworkUse() throws {
        let networking = FakeNetworking(payload: Data())
        let engine = TransferEngine(workingDirectory: workDirectory, networking: networking)
        let collector = EventCollector()
        engine.setEventHandler { collector.record($0, $1) }

        let job = makeJob(source: "http://insecure.example.com/game.pkg")
        engine.enqueue(job)
        XCTAssertTrue(collector.wait())
        XCTAssertEqual(collector.lastFinishedJob?.state, .failed)
        XCTAssertTrue(networking.downloads.isEmpty)
    }

    func testSuccessfulDownloadAndUploadCompletes() throws {
        let payload = Data(repeating: 0x7A, count: 64 * 1024)
        let networking = FakeNetworking(payload: payload, reportedSize: Int64(payload.count))

        // 1 control socket for the engine's FTP session + 1 data socket.
        let control = ScriptedSocket(responses: ["220 ready", "227 Entering Passive Mode (127,0,0,1,196,52)", "150 go", "226 done"].map { Data(($0 + "\r\n").utf8) })
        let data = ScriptedSocket(responses: [])
        let provider = ScriptedProvider([control, data])

        let engine = TransferEngine(workingDirectory: workDirectory, networking: networking, ftpProvider: provider)
        let collector = EventCollector()
        engine.setEventHandler { collector.record($0, $1) }

        engine.enqueue(makeJob())
        XCTAssertTrue(collector.wait())
        let job = try XCTUnwrap(collector.lastFinishedJob)
        XCTAssertEqual(job.state, .completed, job.message)
        XCTAssertEqual(job.uploadedBytes, Int64(payload.count))
        XCTAssertEqual(job.expectedTotalBytes, Int64(payload.count))
        XCTAssertTrue(collector.states.contains(.downloading))
        XCTAssertTrue(collector.states.contains(.connecting))
        XCTAssertTrue(collector.states.contains(.transferring))
        XCTAssertTrue(control.commands.contains("STOR god-of-war-ragnarok.pkg"))
        // Temporary file deleted after success.
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.localURL(for: job).path))
    }

    func testDownloadFailureIsReportedAsErrorNotSuccess() throws {
        let networking = FakeNetworking(payload: Data())
        networking.failWith = FTPError.timeout("servidor lento")
        let engine = TransferEngine(workingDirectory: workDirectory, networking: networking, ftpProvider: ScriptedProvider([]))
        let collector = EventCollector()
        engine.setEventHandler { collector.record($0, $1) }

        engine.enqueue(makeJob())
        XCTAssertTrue(collector.wait())
        let job = try XCTUnwrap(collector.lastFinishedJob)
        XCTAssertEqual(job.state, .failed)
        XCTAssertTrue(job.message.contains("Tempo esgotado"))
    }

    func testFTPUnavailableFailsWithConsoleMessage() throws {
        let payload = Data(repeating: 0x1, count: 4096)
        let networking = FakeNetworking(payload: payload, reportedSize: Int64(payload.count))
        let engine = TransferEngine(workingDirectory: workDirectory, networking: networking, ftpProvider: ScriptedProvider([]))
        let collector = EventCollector()
        engine.setEventHandler { collector.record($0, $1) }

        engine.enqueue(makeJob())
        XCTAssertTrue(collector.wait())
        let job = try XCTUnwrap(collector.lastFinishedJob)
        XCTAssertEqual(job.state, .failed)
        XCTAssertFalse(job.message.isEmpty)
        XCTAssertEqual(collector.lastFinishedJob?.state.isTerminal, true)
    }

    func testJobsRunSequentially() throws {
        let payload = Data(repeating: 0x5, count: 1024)
        let networking = FakeNetworking(payload: payload, reportedSize: Int64(payload.count))
        let engine = TransferEngine(workingDirectory: workDirectory, networking: networking, ftpProvider: ScriptedProvider([]))
        let collector = EventCollector()
        engine.setEventHandler { collector.record($0, $1) }

        engine.enqueue(makeJob())
        engine.enqueue(makeJob())
        XCTAssertTrue(collector.wait())
        // Wait for both to finish.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, collector.states.filter({ $0 == .failed }).count < 2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(collector.states.filter { $0 == .failed }.count, 2)
    }

    func testCancelWhileQueuedProducesCancelledResult() throws {
        let engine = TransferEngine(workingDirectory: workDirectory, networking: FakeNetworking(payload: Data(), reportedSize: 10), ftpProvider: ScriptedProvider([]))
        let collector = EventCollector()
        engine.setEventHandler { collector.record($0, $1) }
        let first = makeJob()
        let second = makeJob()
        engine.enqueue(first)
        engine.enqueue(second)
        // Give the queue a moment to start the first job, then cancel the second.
        Thread.sleep(forTimeInterval: 0.2)
        engine.cancel(jobID: second.id)
        engine.cancelAll()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let terminal = collector.states.filter(\.isTerminal).count
            if terminal >= 2 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(collector.states.contains(.cancelled))
    }

    func testDiscardTemporaryFileRemovesArtifact() throws {
        let engine = TransferEngine(workingDirectory: workDirectory, networking: FakeNetworking(payload: Data()), ftpProvider: ScriptedProvider([]))
        let job = makeJob()
        let url = engine.localURL(for: job)
        try Data("pkg".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        engine.discardTemporaryFile(for: job)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, FileManager.default.fileExists(atPath: url.path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

final class ProgressMathTests: XCTestCase {

    func testOverallProgressCombinesPhases() {
        XCTAssertEqual(ProgressMath.overall(downloaded: 100, uploaded: 0, total: 100), 0.5)
        XCTAssertEqual(ProgressMath.overall(downloaded: 100, uploaded: 100, total: 100), 1.0)
        XCTAssertEqual(ProgressMath.overall(downloaded: 50, uploaded: 50, total: 100), 0.5)
        XCTAssertEqual(ProgressMath.overall(downloaded: 0, uploaded: 0, total: 0), 0)
    }

    func testSmoothedSpeed() {
        XCTAssertEqual(ProgressMath.smoothed(previous: 0, sample: 10), 10)
        XCTAssertEqual(ProgressMath.smoothed(previous: 10, sample: 20, factor: 0.5), 15)
    }

    func testJobProgressUsesExpectedTotal() {
        var job = TransferJob(gameID: UUID(), gameName: "A", coverURLString: "", sourceURLString: "https://x/y.pkg", remoteFileName: "y.pkg", consoleName: "PS4", consoleHost: "1.2.3.4", consolePort: 2121, expectedTotalBytes: 100)
        job.state = .transferring
        job.uploadedBytes = 64
        XCTAssertEqual(job.progress, 0.64, accuracy: 0.001)
        XCTAssertEqual(job.percentageText, "64%")
    }
}
