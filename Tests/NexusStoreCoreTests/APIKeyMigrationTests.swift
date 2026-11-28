import Foundation
import XCTest
@testable import NexusStoreCore

/// The assistant used to keep a single key. These tests pin the move to per-provider slots so an
/// existing installation does not silently lose its key after the update.
final class APIKeyMigrationTests: XCTestCase {

    private func stores(
        legacy: String? = nil,
        rawg: String? = nil,
        gemini: String? = nil
    ) -> (legacy: InMemoryAPIKeyStore, rawg: InMemoryAPIKeyStore, gemini: InMemoryAPIKeyStore) {
        (
            legacy: InMemoryAPIKeyStore(value: legacy),
            rawg: InMemoryAPIKeyStore(value: rawg),
            gemini: InMemoryAPIKeyStore(value: gemini)
        )
    }

    func testGoogleShapedLegacyKeyMovesToGemini() {
        let googleKey = "AIzaSy" + String(repeating: "9", count: 30)
        let s = stores(legacy: googleKey)
        let destination = APIKeyMigration.run(legacy: s.legacy, rawg: s.rawg, gemini: s.gemini)

        XCTAssertEqual(destination, APIKeyMigration.Destination.gemini)
        XCTAssertEqual(s.gemini.apiKey(), googleKey)
        XCTAssertNil(s.rawg.apiKey(), "uma chave do Google não pode cair no campo da RAWG")
        XCTAssertNil(s.legacy.apiKey(), "o item antigo deve ser removido")
    }

    func testRawgShapedLegacyKeyMovesToRawg() {
        let rawgKey = String(repeating: "a1b2c3d4", count: 4)
        let s = stores(legacy: rawgKey)
        XCTAssertEqual(APIKeyMigration.run(legacy: s.legacy, rawg: s.rawg, gemini: s.gemini), APIKeyMigration.Destination.rawg)
        XCTAssertEqual(s.rawg.apiKey(), rawgKey)
        XCTAssertNil(s.gemini.apiKey())
    }

    func testExistingKeysAreNeverOverwritten() {
        let s = stores(legacy: "AIzaSy" + String(repeating: "9", count: 30), gemini: "AIzaSyNew")
        APIKeyMigration.run(legacy: s.legacy, rawg: s.rawg, gemini: s.gemini)
        XCTAssertEqual(s.gemini.apiKey(), "AIzaSyNew")
    }

    func testNothingToMigrateIsANoOp() {
        let s = stores(legacy: "")
        XCTAssertEqual(APIKeyMigration.run(legacy: s.legacy, rawg: s.rawg, gemini: s.gemini), APIKeyMigration.Destination.none)
        XCTAssertNil(s.rawg.apiKey())
        XCTAssertNil(s.gemini.apiKey())
    }

    func testDestinationClassification() {
        XCTAssertEqual(APIKeyMigration.destination(forLegacyKey: "AIzaSy" + String(repeating: "x", count: 30)), APIKeyMigration.Destination.gemini)
        XCTAssertEqual(APIKeyMigration.destination(forLegacyKey: "0123456789abcdef0123456789abcdef"), APIKeyMigration.Destination.rawg)
        XCTAssertEqual(APIKeyMigration.destination(forLegacyKey: "   "), APIKeyMigration.Destination.none)
    }

    func testEachProviderKeepsItsOwnKey() throws {
        // Mirrors AutoCatalogStore: switching model must not move or erase either key.
        let rawg = InMemoryAPIKeyStore()
        let gemini = InMemoryAPIKeyStore()
        try rawg.save("rawg-key-value")
        try gemini.save("AIzaSyGeminiKeyValue")
        XCTAssertEqual(rawg.apiKey(), "rawg-key-value")
        XCTAssertEqual(gemini.apiKey(), "AIzaSyGeminiKeyValue")
    }
}
