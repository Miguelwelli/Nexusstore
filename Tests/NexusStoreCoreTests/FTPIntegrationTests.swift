import XCTest
@testable import NexusStoreCore

/// End-to-end tests against a **real** FTP server (pyftpdlib) started by CI.
///
/// Enabled only when `NEXUS_FTP_INTEGRATION=1`, so `swift test` on a machine without a server stays
/// green. When enabled, these tests exercise the same code path used to send packages to a console:
/// TCP connect → greeting → USER/PASS → TYPE I → PASV → STOR (real bytes on disk) → SIZE/LIST.
final class FTPIntegrationTests: XCTestCase {

    private var host: String { ProcessInfo.processInfo.environment["NEXUS_FTP_HOST"] ?? "127.0.0.1" }
    private var port: UInt16 { UInt16(ProcessInfo.processInfo.environment["NEXUS_FTP_PORT"] ?? "2121") ?? 2121 }
    private var user: String { ProcessInfo.processInfo.environment["NEXUS_FTP_USER"] ?? "ps4" }
    private var password: String { ProcessInfo.processInfo.environment["NEXUS_FTP_PASSWORD"] ?? "ps4" }

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["NEXUS_FTP_INTEGRATION"] == "1"
    }

    func testUploadsFileToRealServerAndVerifiesSize() throws {
        try XCTSkipUnless(isEnabled, "set NEXUS_FTP_INTEGRATION=1 with a running server to enable")

        // 2 MiB of deterministic bytes: larger than one 64 KiB chunk to exercise the streaming loop.
        var payload = Data()
        for index in 0..<(2 * 1024 * 1024) {
            payload.append(UInt8(index % 251))
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-integration-\(UUID().uuidString).pkg")
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let client = FTPClient()
        try client.connect(host: host, port: port, timeout: 10)
        try client.login(user: user, password: password)
        _ = try client.systemType()
        try client.enterBinaryMode()
        XCTAssertFalse(try client.currentDirectory().isEmpty)

        var updates: [Int64] = []
        let remoteName = "nexus-test-\(UUID().uuidString).pkg"
        let sent = try client.upload(fileURL: fileURL, remoteName: remoteName) { written, total in
            updates.append(written)
            XCTAssertLessThanOrEqual(written, total)
        }
        XCTAssertEqual(sent, Int64(payload.count))
        XCTAssertEqual(updates.last, Int64(payload.count))
        XCTAssertGreaterThan(updates.count, 1, "progress must be reported incrementally")

        // SIZE is optional in FTP; when the server implements it the values must match exactly.
        if let remoteSize = client.remoteFileSize(remoteName) {
            XCTAssertEqual(remoteSize, Int64(payload.count))
        }

        let listing = try client.listDirectory()
        XCTAssertTrue(listing.contains { $0.name == remoteName }, "uploaded file must appear in LIST")
        client.quitSilently()
    }

    func testWrongPasswordIsRejectedByRealServer() throws {
        try XCTSkipUnless(isEnabled, "set NEXUS_FTP_INTEGRATION=1 with a running server to enable")
        let client = FTPClient()
        try client.connect(host: host, port: port, timeout: 10)
        XCTAssertThrowsError(try client.login(user: user, password: "senha-errada-\(UUID().uuidString)")) { error in
            guard case FTPError.loginFailed = error else {
                return XCTFail("expected loginFailed, got \(error)")
            }
        }
    }

    func testConnectionToUnusedPortFails() throws {
        try XCTSkipUnless(isEnabled, "set NEXUS_FTP_INTEGRATION=1 with a running server to enable")
        let client = FTPClient()
        XCTAssertThrowsError(try client.connect(host: host, port: port + 1, timeout: 2))
    }
}
