import XCTest
@testable import NexusStoreCore

final class ByteFormattingTests: XCTestCase {

    func testParsesGigabytesWithDotAndComma() {
        XCTAssertEqual(ByteFormatting.parseSize("48.5 GB"), 52_076_478_464)
        XCTAssertEqual(ByteFormatting.parseSize("48,5 gb"), 52_076_478_464)
        XCTAssertEqual(ByteFormatting.parseSize("48.5GB"), 52_076_478_464)
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
        XCTAssertEqual(ByteFormatting.formatSize(52_076_478_464), "48.5 GB")
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

final class ArtworkReferenceTests: XCTestCase {

    func testBundledAssetNameIsAccepted() {
        XCTAssertEqual(ArtworkReference(rawValue: "cover_ghost").bundledName, "cover_ghost")
        XCTAssertTrue(ArtworkReference(rawValue: "cover_ghost").isValid)
    }

    func testRemoteHTTPSArtwork() {
        let reference = ArtworkReference(rawValue: "https://cdn.example.com/cover.jpg")
        XCTAssertNotNil(reference.remoteURL)
        XCTAssertTrue(reference.isValid)
    }

    func testInvalidArtworkIsRejected() {
        XCTAssertFalse(ArtworkReference(rawValue: "http://cdn.example.com/cover.jpg").isValid)
        XCTAssertFalse(ArtworkReference(rawValue: "  ").isValid)
        XCTAssertEqual(ArtworkReference(rawValue: ""), .none)
    }

    func testPackageSlug() {
        let game = Game(name: "God of War Ragnarök", downloadURLString: "")
        XCTAssertEqual(game.remotePackageName, "god-of-war-ragnarok.pkg")
        let withURL = Game(name: "X", downloadURLString: "https://cdn.example.com/pkg/ghost_v2.pkg")
        XCTAssertEqual(withURL.remotePackageName, "ghost_v2.pkg")
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

final class AdminCredentialTests: XCTestCase {

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256Hash.hex(SHA256Hash.digest(Data("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Hash.hex(SHA256Hash.digest(Data("".utf8))),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let long = String(repeating: "a", count: 1000)
        XCTAssertEqual(SHA256Hash.hex(SHA256Hash.digest(Data(long.utf8))),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testPasswordValidationAndHashing() {
        XCTAssertNotNil(AdminCredential.validate(password: "123"))
        XCTAssertNil(AdminCredential.validate(password: "1234"))
        XCTAssertNotNil(AdminCredential.validate(password: " 1234"))

        let salt = AdminCredential.makeSalt()
        let hash = AdminCredential.hash(password: "senha", salt: salt)
        XCTAssertEqual(hash, AdminCredential.hash(password: "senha", salt: salt))
        XCTAssertNotEqual(hash, AdminCredential.hash(password: "senha", salt: salt + "x"))
        XCTAssertEqual(hash.count, 64)
    }
}
