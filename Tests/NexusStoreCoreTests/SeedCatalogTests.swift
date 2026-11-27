import XCTest
@testable import NexusStoreCore

final class SeedCatalogTests: XCTestCase {

    private var games: [Game] = []

    override func setUpWithError() throws {
        games = SeedCatalogBridge.load()
    }

    func testSeedCatalogShipsAndIsNotEmpty() {
        XCTAssertFalse(games.isEmpty, "Resources/Seed/seed-catalog.json is missing or invalid")
    }

    func testEverySeedGameIsValidAndSelfConsistent() {
        for game in games {
            XCTAssertFalse(game.name.isEmpty)
            XCTAssertGreaterThan(game.byteCount, 0, "size not parseable for \(game.name)")
            XCTAssertNotNil(game.downloadURL, "invalid download URL for \(game.name)")
            XCTAssertFalse(game.categories.isEmpty, "no category for \(game.name)")
            XCTAssertTrue(game.categories.allSatisfy { GameCategory(rawValue: $0) != nil }, "unknown category in \(game.name)")
        }
    }

    func testSeedLinksAreClearlyMarkedAsExamples() {
        // The sample data must never point at a real host: transfers would otherwise look real.
        for game in games {
            XCTAssertTrue(game.downloadURLString.contains("exemplo"), "seed game \(game.name) must not use a routable link")
        }
    }

    func testSeededNamesAreRecognisedAsSamples() {
        XCTAssertEqual(Set(games.map(\.name)), SeedCatalog.sampleNames)
    }

    func testSeedSortsAndFilters() {
        XCTAssertNotNil(CatalogQuery.featured(in: games))
        XCTAssertEqual(CatalogQuery.recentlyAdded(in: games).count, min(6, games.count))
        let ghosts = CatalogQuery.apply(games, filter: CatalogFilter(searchText: "tsushima"))
        XCTAssertGreaterThanOrEqual(ghosts.count, 1)
    }
}
