import XCTest
@testable import NexusStoreCore

/// A scripted FTP server: every scripted reply is consumed by one read.
private func server(_ lines: [String]) -> ScriptedSocket {
    ScriptedSocket(responses: lines.map { $0 + "\r\n" })
}

final class FTPClientTests: XCTestCase {

    func testConnectReadsGreeting() throws {
        let socket = server(["220 PS4 FTP Server ready"])
        let provider = ScriptedProvider([socket])
        let client = FTPClient(provider: provider)
        try client.connect(host: "192.168.1.104", port: 2121)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(socket.connectCalls.first?.0, "192.168.1.104")
        XCTAssertEqual(socket.connectCalls.first?.1, 2121)
    }

    func testConnectFailsWhenServerDoesNotGreet() {
        let socket = server(["500 oops"])
        let client = FTPClient(provider: ScriptedProvider([socket]))
        XCTAssertThrowsError(try client.connect(host: "10.0.0.2", port: 21))
        XCTAssertFalse(client.isConnected)
    }

    func testLoginWithPassword() throws {
        let socket = server(["220 ready", "331 password required", "230 logged in"])
        let client = FTPClient(provider: ScriptedProvider([socket]))
        try client.connect(host: "10.0.0.1", port: 2121)
        try client.login(user: "anonymous", password: "x")
        XCTAssertEqual(socket.commands, ["USER anonymous", "PASS x"])
    }

    func testLoginAlreadyAuthenticated() throws {
        let socket = server(["220 ready", "230 welcome"])
        let client = FTPClient(provider: ScriptedProvider([socket]))
        try client.connect(host: "10.0.0.1", port: 2121)
        try client.login(user: "ps4", password: "")
        XCTAssertEqual(socket.commands, ["USER ps4"])
    }

    func testLoginRejectedThrows() {
        let socket = server(["220 ready", "331 password required", "530 Login incorrect"])
        let client = FTPClient(provider: ScriptedProvider([socket]))
        XCTAssertNoThrow(try client.connect(host: "10.0.0.1", port: 2121))
        XCTAssertThrowsError(try client.login(user: "ps4", password: "wrong")) { error in
            guard case FTPError.loginFailed = error else { return XCTFail("expected loginFailed") }
        }
    }

    func testMultilineRepliesAreJoined() throws {
        let socket = ScriptedSocket(responses: [
            Data("220-Welcome to PS4\r\n220-This is a demo\r\n220 Ready\r\n".utf8)
        ])
        let client = FTPClient(provider: ScriptedProvider([socket]))
        try client.connect(host: "10.0.0.1", port: 2121)
        XCTAssertTrue(client.isConnected)
    }

    func testPassiveModeParsesPASV() throws {
        let socket = server(["220 ready", "227 Entering Passive Mode (192,168,1,104,196,52)."])
        let client = FTPClient(provider: ScriptedProvider([socket]))
        try client.connect(host: "192.168.1.104", port: 2121)
        let endpoint = try client.passiveEndpoint()
        XCTAssertEqual(endpoint.host, "192.168.1.104")
        XCTAssertEqual(endpoint.port, 196 * 256 + 52) // 50228
        XCTAssertEqual(socket.commands, ["PASV"])
    }

    func testPassiveModeFallsBackToEPSV() throws {
        let socket = server(["220 ready", "500 PASV not understood", "229 Entering Extended Passive Mode (|||24812|)"])
        let client = FTPClient(provider: ScriptedProvider([socket]))
        try client.connect(host: "192.168.1.104", port: 2121)
        let endpoint = try client.passiveEndpoint()
        XCTAssertEqual(endpoint.port, 24812)
        XCTAssertEqual(socket.commands, ["PASV", "EPSV"])
    }

    func testUnroutablePASVAddressIsReplacedByControlHost() throws {
        let socket = server(["220 ready", "227 Entering Passive Mode (0,0,0,0,10,10)"])
        let client = FTPClient(provider: ScriptedProvider([socket]))
        try client.connect(host: "192.168.0.50", port: 2121)
        let endpoint = try client.passiveEndpoint()
        XCTAssertEqual(endpoint.host, "192.168.0.50")
        XCTAssertEqual(endpoint.port, 2570)
    }

    func testUploadStreamsFileThroughDataConnection() throws {
        let payload = Data(repeating: 0x41, count: 150 * 1024) // 150 KiB -> 3 chunks of 64 KiB
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).pkg")
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let control = server([
            "220 ready",
            "227 Entering Passive Mode (192,168,1,104,196,52)",
            "150 Opening data connection",
            "226 Transfer complete"
        ])
        let data = ScriptedSocket(responses: [])
        let provider = ScriptedProvider([control, data])
        let client = FTPClient(provider: provider)
        try client.connect(host: "192.168.1.104", port: 2121)
        _ = try client.enterBinaryMode()
        // TYPE I needs a reply
        XCTAssertEqual(control.commands.prefix(1), ["TYPE I"])

        var updates: [Int64] = []
        let sent = try client.upload(fileURL: fileURL, remoteName: "game.pkg", progress: { written, _ in
            updates.append(written)
        })
        XCTAssertEqual(sent, Int64(payload.count))
        XCTAssertEqual(updates.last, Int64(payload.count))
        XCTAssertEqual(updates.count, 3)
        XCTAssertTrue(control.commands.contains("PASV"))
        XCTAssertTrue(control.commands.contains("STOR game.pkg"))
        XCTAssertTrue(data.isOpen == false, "data socket must be closed after upload")
    }

    func testUploadHonoursCancellation() throws {
        let payload = Data(repeating: 0x42, count: 200 * 1024)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString).pkg")
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let control = server([
            "220 ready",
            "227 Entering Passive Mode (127,0,0,1,196,52)",
            "150 Opening data connection"
        ])
        let data = ScriptedSocket(responses: [])
        let client = FTPClient(provider: ScriptedProvider([control, data]))
        try client.connect(host: "127.0.0.1", port: 2121)
        XCTAssertThrowsError(try client.upload(fileURL: fileURL, remoteName: "a.pkg", progress: { _, _ in }, isCancelled: { true })) { error in
            XCTAssertEqual(error as? FTPError, .cancelled)
        }
    }

    func testListDirectoryParsesLIST() {
        XCTAssertEqual(FTPClient.parseListLine("-rw-r--r-- 1 root root 1234 Jan 01 12:00 game.pkg"),
                       FTPClient.RemoteEntry(name: "game.pkg", isDirectory: false, size: 1234))
        XCTAssertEqual(FTPClient.parseListLine("drwxr-xr-x 2 root root 4096 Jan 01 12:00 packages"),
                       FTPClient.RemoteEntry(name: "packages", isDirectory: true, size: 4096))
        XCTAssertNil(FTPClient.parseListLine("garbage"))
    }

    func testLeadingCodeParsing() {
        XCTAssertEqual(FTPClient.leadingCode("220 Hello"), 220)
        XCTAssertNil(FTPClient.leadingCode("abc"))
        XCTAssertNil(FTPClient.leadingCode("22"))
    }

    func testRealSocketConnectionToClosedPortFailsHonestly() {
        // 127.0.0.1:1 is reserved and never listening; the client must surface a network error.
        let client = FTPClient()
        XCTAssertThrowsError(try client.connect(host: "127.0.0.1", port: 1, timeout: 1)) { error in
            guard case FTPError.socket = error else { return XCTFail("expected socket error, got \(error)") }
        }
    }
}
