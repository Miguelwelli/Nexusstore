import XCTest
@testable import NexusStoreCore

final class ByteFormattingTests: XCTestCase {

    func testParsesGigabytesWithDotAndComma() {
        XCTAssertEqual(ByteFormatting.parseSize("48.5 GB"), 52_065_992_704)
        XCTAssertEqual(ByteFormatting.parseSize("48,5 gb"), 52_065_992_704)
        XCTAssertEqual(ByteFormatting.parseSize("48.5GB"), 52_065_992_704)
        XCTAssertEqual(ByteFormatting.parseSize("  1 TB "), 1_099_511_627_776)
    }

    func testParsesMegabytesAndRawBytes() {
        XCTAssertEqual(ByteFormatting.parseSize("900 MB"), 943_718_400)
        XCTAssertEqual(ByteFormatting.parseSize("1024"), 1024)
    }

    func testRejectsInvalidSizes() {
        XCTAssertNil(ByteFormatting.parseSize(""))
        XCTAssertNil(ByteFormatting.parseSize("grande"))
        XCTAssertNil(ByteFormatting.parseSize("GB"))
        XCTAssertNil(ByteFormatting.parseSize("-5 GB"))
        XCTAssertNil(ByteFormatting.parseSize("12 XB"))
    }

    func testFormatting() {
        XCTAssertEqual(ByteFormatting.formatSize(52_065_992_704), "48.5 GB")
        XCTAssertEqual(ByteFormatting.formatSize(943_718_400), "900.0 MB")
        XCTAssertEqual(ByteFormatting.formatSize(0), "—")
    }

    func testSpeedsAndRemainingTime() {
        XCTAssertEqual(ByteFormatting.formatSpeed(96_888_012), "92.4 MB/s")
        XCTAssertEqual(ByteFormatting.formatSpeed(0), "0 MB/s")
        XCTAssertEqual(ByteFormatting.formatRemaining(seconds: 30), "menos de 1 min")
        XCTAssertEqual(ByteFormatting.formatRemaining(seconds: 300), "~5 min")
        XCTAssertEqual(ByteFormatting.formatRemaining(seconds: 3_600), "~1h")
        XCTAssertEqual(ByteFormatting.formatRemaining(seconds: nil), "—")
    }

    func testPercentageIsClamped() {
        XCTAssertEqual(ByteFormatting.percentage(transferred: 50, total: 100), 50)
        XCTAssertEqual(ByteFormatting.percentage(transferred: 120, total: 100), 100)
        XCTAssertEqual(ByteFormatting.percentage(transferred: 10, total: 0), 0)
    }
}

final class URLValidatorTests: XCTestCase {

    func testAcceptsHTTPSPackageLinks() {
        XCTAssertNil(HTTPSURLValidator.validate("https://cdn.example.com/pkg/game_v1.pkg", requiringPKG: true))
        XCTAssertNotNil(HTTPSURLValidator.url(from: "https://cdn.example.com/a.pkg"))
    }

    func testRejectsHTTPAndMalformedLinks() {
        XCTAssertEqual(HTTPSURLValidator.validate("http://cdn.example.com/a.pkg", requiringPKG: true), .insecureScheme)
        XCTAssertEqual(HTTPSURLValidator.validate("ftp://cdn.example.com/a.pkg", requiringPKG: true), .insecureScheme)
        XCTAssertEqual(HTTPSURLValidator.validate("https://cdn.example.com/a.zip", requiringPKG: true), .notPKG)
        XCTAssertEqual(HTTPSURLValidator.validate("   ", requiringPKG: false), .empty)
        XCTAssertNil(HTTPSURLValidator.url(from: "não é um link"))
    }

    func testErrorMessageForKeyCases() {
        XCTAssertTrue(URLValidationError.insecureScheme.message.contains("HTTPS"))
        XCTAssertTrue(URLValidationError.notPKG.message.contains(".pkg"))
    }

    func testSuggestedFileName() {
        let url = URL(string: "https://cdn.example.com/pkg/ghost_v2.pkg")!
        XCTAssertEqual(HTTPSURLValidator.suggestedFileName(for: url, fallback: "jogo.pkg"), "ghost_v2.pkg")
    }
}
