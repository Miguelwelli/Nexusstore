import XCTest
@testable import NexusStoreCore

final class GameDraftValidationTests: XCTestCase {

    func makeValidDraft() -> GameDraft {
        var draft = GameDraft()
        draft.name = "Ghost of Tsushima"
        draft.categories = ["acao", "mundo-aberto"]
        draft.sizeText = "48.5 GB"
        draft.version = "2.18"
        draft.downloadURLString = "https://cdn.example.com/ghost.pkg"
        return draft
    }

    func testValidDraftPasses() {
        XCTAssertTrue(makeValidDraft().isValid)
    }

    func testReportsEveryProblemAtOnce() {
        let errors = GameDraft().validate()
        XCTAssertEqual(Set(errors.keys), [.name, .categories, .size, .version, .downloadURL])
    }

    func testRejectsHTTPAndNonPackageLinks() {
        var draft = makeValidDraft()
        draft.downloadURLString = "http://cdn.example.com/ghost.pkg"
        XCTAssertNotNil(draft.validate()[.downloadURL])

        draft.downloadURLString = "https://cdn.example.com/ghost.zip"
        XCTAssertNotNil(draft.validate()[.downloadURL])
    }

    func testRejectsUnknownCategoryAndBadSize() {
        var draft = makeValidDraft()
        draft.categories = ["nao-existe"]
        XCTAssertNotNil(draft.validate()[.categories])

        draft = makeValidDraft()
        draft.sizeText = "muito grande"
        XCTAssertNotNil(draft.validate()[.size])
    }

    func testMakeGameTrimsAndSplitsTags() {
        var draft = makeValidDraft()
        draft.name = "  Bloodborne  "
        draft.tagsText = "1 Jogador, PT-BR ,  , HDR"
        let game = draft.makeGame()
        XCTAssertEqual(game.name, "Bloodborne")
        XCTAssertEqual(game.tags, ["1 Jogador", "PT-BR", "HDR"])
        XCTAssertEqual(game.byteCount, 52_076_478_464)
    }

    func testEditingKeepsIdentityAndCreationDate() {
        let existing = makeValidDraft().makeGame()
        var draft = GameDraft(game: existing)
        draft.name = "Ghost of Tsushima: Director's Cut"
        let updated = draft.makeGame(existing: existing, now: existing.createdAt.addingTimeInterval(60))
        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(updated.createdAt, existing.createdAt)
        XCTAssertGreaterThan(updated.updatedAt, existing.updatedAt)
    }
}

final class CatalogRepositoryTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("catalog.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sampleGame(name: String = "God of War Ragnarök", categories: [String] = ["acao", "rpg"]) -> Game {
        Game(
            name: name,
            description: "Kratos e Atreus viajam pelos Nove Reinos.",
            categories: categories,
            sizeText: "84.3 GB",
            version: "1.04",
            downloadURLString: "https://cdn.example.com/gow.pkg",
            coverURLString: "",
            bannerURLString: "",
            rating: 4.9,
            ratingCount: 12_500
        )
    }

    func testAddPersistsAcrossInstances() throws {
        let repository = try CatalogRepository(fileURL: fileURL)
        try repository.add(sampleGame())
        XCTAssertEqual(repository.games.count, 1)

        let reopened = try CatalogRepository(fileURL: fileURL)
        XCTAssertEqual(reopened.games.count, 1)
        XCTAssertEqual(reopened.games.first?.name, "God of War Ragnarök")
        XCTAssertEqual(reopened.games.first?.categories, ["acao", "rpg"])
    }

    func testDuplicateNamesAreRejected() throws {
        let repository = try CatalogRepository(fileURL: fileURL)
        try repository.add(sampleGame(name: "Bloodborne"))
        XCTAssertThrowsError(try repository.add(sampleGame(name: "bloodborne"))) { error in
            guard case CatalogError.duplicateName = error else {
                return XCTFail("expected duplicateName, got \(error)")
            }
        }
    }

    func testUpdateAndDelete() throws {
        let repository = try CatalogRepository(fileURL: fileURL)
        var game = sampleGame()
        try repository.add(game)
        game.name = "God of War Ragnarök (Deluxe)"
        try repository.update(game)
        XCTAssertEqual(repository.game(id: game.id)?.name, "God of War Ragnarök (Deluxe)")

        try repository.delete(id: game.id)
        XCTAssertTrue(repository.games.isEmpty)
        XCTAssertThrowsError(try repository.delete(id: game.id))
    }

    func testFavoritesAndRecentlyViewed() throws {
        let repository = try CatalogRepository(fileURL: fileURL)
        let first = sampleGame(name: "A")
        let second = sampleGame(name: "B")
        try repository.add(first)
        try repository.add(second)
        try repository.setFavorite(first.id, isFavorite: true)
        XCTAssertEqual(repository.favorites, [first.id])
        try repository.setFavorite(first.id, isFavorite: false)
        XCTAssertTrue(repository.favorites.isEmpty)

        try repository.recordView(first.id)
        try repository.recordView(second.id)
        XCTAssertEqual(repository.recentlyViewedGames.map(\.id), [second.id, first.id])
        try repository.recordView(first.id)
        XCTAssertEqual(repository.recentlyViewedGames.map(\.id), [first.id, second.id])
    }

    func testDeletingEveryGameDoesNotReseed() throws {
        let seed = [sampleGame(name: "Seed")]
        let repository = try CatalogRepository(fileURL: fileURL, seed: seed)
        XCTAssertEqual(repository.games.count, 1)
        try repository.delete(id: repository.games[0].id)
        let reopened = try CatalogRepository(fileURL: fileURL, seed: seed)
        XCTAssertTrue(reopened.games.isEmpty)
        XCTAssertTrue(reopened.snapshot.didSeed)
    }

    func testCorruptedFileFallsBackToEmptyCatalog() throws {
        try Data("not json".utf8).write(to: fileURL)
        let repository = try CatalogRepository(fileURL: fileURL)
        XCTAssertTrue(repository.games.isEmpty)
    }

    func testFileIsWrittenAtomicallyAndDecodable() throws {
        let repository = try CatalogRepository(fileURL: fileURL)
        try repository.add(sampleGame())
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)
        XCTAssertEqual(snapshot.schemaVersion, CatalogSnapshot.currentSchemaVersion)
    }
}

final class CatalogQueryTests: XCTestCase {

    private func games() -> [Game] {
        [
            Game(name: "Ghost of Tsushima", description: "Samurai em ação", categories: ["acao", "mundo-aberto"], sizeText: "48.5 GB", createdAt: Date(timeIntervalSince1970: 100), rating: 4.9, ratingCount: 18_400),
            Game(name: "Bloodborne", description: "Action RPG soulslike", categories: ["acao", "soulslike"], sizeText: "36.2 GB", createdAt: Date(timeIntervalSince1970: 300), rating: 4.8, ratingCount: 9_000),
            Game(name: "God of War Ragnarök", description: "Aventura nórdica", categories: ["acao", "aventura"], sizeText: "84.3 GB", createdAt: Date(timeIntervalSince1970: 200), isFeatured: true, rating: 4.9, ratingCount: 24_800)
        ]
    }

    func testSearchIsDiacriticAndCaseInsensitive() {
        let results = CatalogQuery.apply(games(), filter: CatalogFilter(searchText: "RAGNAROK"))
        XCTAssertEqual(results.map(\.name), ["God of War Ragnarök"])
        let accents = CatalogQuery.apply(games(), filter: CatalogFilter(searchText: "nordica"))
        XCTAssertEqual(accents.map(\.name), ["God of War Ragnarök"])
    }

    func testCategoryFilterAcceptsMultipleCategories() {
        let results = CatalogQuery.apply(games(), filter: CatalogFilter(categories: ["soulslike"]))
        XCTAssertEqual(results.map(\.name), ["Bloodborne"])
        let union = CatalogQuery.apply(games(), filter: CatalogFilter(categories: ["soulslike", "aventura"]))
        XCTAssertEqual(Set(union.map(\.name)), ["Bloodborne", "God of War Ragnarök"])
    }

    func testSorting() {
        XCTAssertEqual(CatalogQuery.apply(games(), filter: CatalogFilter(sort: .popular)).first?.name, "God of War Ragnarök")
        XCTAssertEqual(CatalogQuery.apply(games(), filter: CatalogFilter(sort: .recent)).first?.name, "Bloodborne")
        XCTAssertEqual(CatalogQuery.apply(games(), filter: CatalogFilter(sort: .name)).first?.name, "Bloodborne")
        XCTAssertEqual(CatalogQuery.apply(games(), filter: CatalogFilter(sort: .size)).first?.name, "God of War Ragnarök")
    }

    func testFeaturedAndRows() {
        XCTAssertEqual(CatalogQuery.featured(in: games())?.name, "God of War Ragnarök")
        XCTAssertEqual(CatalogQuery.recentlyAdded(in: games()).first?.name, "Bloodborne")
        XCTAssertEqual(CatalogQuery.categoryCounts(in: games())["acao"], 3)
    }

    func testEmptyCatalogHasNoFeatured() {
        XCTAssertNil(CatalogQuery.featured(in: []))
        XCTAssertTrue(CatalogQuery.recentlyAdded(in: []).isEmpty)
    }
}
