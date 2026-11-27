import XCTest
@testable import NexusStoreCore

final class PS4DiscoveryProtocolTests: XCTestCase {

    private let awakeResponse = """
    HTTP/1.1 200 Ok\r
    host-id:PS4-PRO-04B2\r
    host-type:PS4\r
    host-name:PS4 PRO - SALA\r
    host-request-port:997\r
    device-discovery-protocol-version:00020020\r
    \r

    """

    func testSearchPacketMatchesDDPFormat() {
        let packet = PS4DiscoveryProtocol.searchPacket()
        let text = String(decoding: packet, as: UTF8.self)
        XCTAssertEqual(text, "SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00020020\n")
    }

    func testParsesAwakeConsole() throws {
        let device = try XCTUnwrap(PS4DiscoveryProtocol.parseResponse(Data(awakeResponse.utf8), from: "192.168.1.104", port: 987))
        XCTAssertEqual(device.hostId, "PS4-PRO-04B2")
        XCTAssertEqual(device.hostName, "PS4 PRO - SALA")
        XCTAssertEqual(device.hostType, "PS4")
        XCTAssertEqual(device.address, "192.168.1.104")
        XCTAssertEqual(device.requestPort, 997)
        XCTAssertTrue(device.isAwake)
        XCTAssertEqual(device.typeDescription, "PlayStation 4")
    }

    func testParsesStandbyConsole() throws {
        let text = "HTTP/1.1 620 Server Standby\r\nhost-id:PS4-SLIM\r\nhost-type:PS4\r\nhost-name:PS4 Slim\r\n\r\n"
        let device = try XCTUnwrap(PS4DiscoveryProtocol.parseResponse(Data(text.utf8), from: "192.168.1.108", port: 987))
        XCTAssertFalse(device.isAwake)
        XCTAssertEqual(device.statusLine, "HTTP/1.1 620 Server Standby")
    }

    func testIgnoresNonConsolePackets() {
        let text = "hello there\nhost-id:1\n"
        XCTAssertNil(PS4DiscoveryProtocol.parseResponse(Data(text.utf8), from: "192.168.1.1", port: 987))
        let noHostId = "HTTP/1.1 200 Ok\r\nhost-name:Something\r\n\r\n"
        XCTAssertNil(PS4DiscoveryProtocol.parseResponse(Data(noHostId.utf8), from: "192.168.1.1", port: 987))
    }

    func testTolerantToLineFeedOnly() throws {
        let text = "HTTP/1.1 200 Ok\nhost-id:ABC\nhost-type:PS4\n\n"
        XCTAssertEqual(PS4DiscoveryProtocol.parseResponse(Data(text.utf8), from: "10.0.0.9", port: 987)?.hostId, "ABC")
    }

    func testDiscovererRequiresLocalNetwork() throws {
        // A very short scan on a sandboxed CI machine either finds nothing or fails to open a socket;
        // in both cases it must return/throw without hanging, and never invent a console.
        let discovery = PS4Discovery()
        do {
            let devices = try discovery.scan(options: .init(timeout: 0.3, searchInterval: 0.1))
            XCTAssertTrue(devices.allSatisfy { !$0.hostId.isEmpty })
        } catch let error as PS4Discovery.DiscoveryError {
            guard case .socketUnavailable = error else {
                return XCTFail("unexpected discovery error \(error)")
            }
        }
    }
}

final class ConsoleProfileTests: XCTestCase {

    func testValidation() {
        XCTAssertNil(ConsoleProfile(name: "PS4", host: "192.168.1.104", port: 2121).validationError())
        XCTAssertNotNil(ConsoleProfile(name: "PS4", host: "", port: 2121).validationError())
        XCTAssertNotNil(ConsoleProfile(name: "PS4", host: "192.168.1.104", port: 0).validationError())
        XCTAssertNotNil(ConsoleProfile(name: "PS4", host: "192.168.1.104", port: 2121, remotePath: "").validationError())
    }

    func testDecodingToleratesMissingPreferredMethod() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"PS4","host":"192.168.1.104","port":2121,"username":"anonymous","remotePath":"/","isManual":true,"notes":""}
        """
        let profile = try JSONDecoder().decode(ConsoleProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.preferredMethod, .ftp)
    }

    func testSendingMethodMatrixIsHonest() {
        XCTAssertTrue(SendingMethod.ftp.isAutomatic)
        XCTAssertTrue(SendingMethod.ps4web.isAutomatic)
        XCTAssertFalse(SendingMethod.httpServer.isAutomatic)
        XCTAssertFalse(SendingMethod.ftp.detail.isEmpty)
    }
}
