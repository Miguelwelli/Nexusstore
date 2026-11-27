import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import NexusStoreCore

/// The assistant is tested against a real HTTP conversation: a fake `URLProtocol` serves RAWG-shaped
/// JSON (and hostile variants), so parsing, duplicate control, link verification and approval are all
/// exercised without touching the network.
final class AutoCatalogTests: XCTestCase {

    // MARK: - URLProtocol stub

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
        nonisolated(unsafe) static var requestedURLs: [URL] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requestedURLs.append(request.url!)
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let (status, headers, data) = handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private var session: URLSession!
    private var directory: URL!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        session = URLSession(configuration: configuration)
        Stub.handler = nil
        Stub.requestedURLs = []
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Stub.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private var rawgPayload: Data {
        let json: [String: Any] = [
            "count": 3,
            "results": [
                [
                    "id": 3498,
                    "slug": "sekiro-shadows-die-twice",
                    "name": "Sekiro: Shadows Die Twice",
                    "released": "2019-03-22",
                    "background_image": "https://media.rawg.io/media/games/sekiro.jpg",
                    "background_image_additional": "https://media.rawg.io/media/games/sekiro-banner.jpg",
                    "rating": 4.42,
                    "ratings_count": 3120,
                    "description_raw": "Ação e aventura no Japão feudal.",
                    "genres": [["name": "Action"], ["name": "Adventure"]],
                    "tags": [["name": "Souls-like"], ["name": "Singleplayer"]],
                    "platforms": [["platform": ["name": "PlayStation 4"]]],
                    "stores": [["store": ["name": "PlayStation Store"]]],
                    "developers": [["name": "FromSoftware"]],
                    "publishers": [["name": "Activision"]]
                ],
                [
                    "id": 3499,
                    "slug": "duplicate-game",
                    "name": "Sekiro Shadows Die Twice",
                    "released": "2019-03-22",
                    "background_image": "https://media.rawg.io/media/games/sekiro2.jpg",
                    "genres": [["name": "Action"]],
                    "platforms": [["platform": ["name": "PlayStation 4"]]]
                ],
                [
                    "id": 3500,
                    "slug": "bloodborne",
                    "name": "Bloodborne",
                    "released": "2015-03-24",
                    "background_image": "https://media.rawg.io/media/games/bloodborne.jpg",
                    "genres": [["name": "Action"], ["name": "RPG"]],
                    "platforms": [["platform": ["name": "PlayStation 4"]]],
                    "developers": [["name": "FromSoftware"]],
                    "publishers": [["name": "Sony Computer Entertainment"]]
                ]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func makeProvider(key: String = "test-key") -> RAWGMetadataProvider {
        RAWGMetadataProvider(apiKey: key, session: session)
    }

    private func makeAssistant() -> AutoCatalogAssistant {
        AutoCatalogAssistant(provider: makeProvider(), verifier: PKGLinkVerifier(session: session))
    }

    // MARK: - Provider

    func testConnectionReportsLatencyAndSendsKeyOnlyToRAWG() async throws {
        Stub.handler = { request in
            XCTAssertEqual(request.url?.host, "api.rawg.io")
            return (200, ["Content-Type": "application/json"], Data("{\"results\":[]}".utf8))
        }
        let latency = try await makeProvider().testConnection()
        XCTAssertGreaterThanOrEqual(latency, 0)
        XCTAssertEqual(Stub.requestedURLs.count, 1)
        XCTAssertTrue(Stub.requestedURLs[0].query?.contains("key=test-key") == true)
    }

    func testUnauthorizedKeyIsReportedAsAuthenticationError() async {
        Stub.handler = { _ in (401, [:], Data()) }
        do {
            _ = try await makeProvider().testConnection()
            XCTFail("era esperado erro de autenticação")
        } catch let error as MetadataProviderError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertTrue(error.errorDescription!.contains("401"))
        } catch {
            XCTFail("erro inesperado: \(error)")
        }
    }

    func testRateLimitCarriesRetryAfter() async {
        Stub.handler = { _ in (429, ["Retry-After": "30"], Data()) }
        do {
            _ = try await makeProvider().search(MetadataQuery(categories: ["acao"], limit: 3))
            XCTFail("era esperado rate limit")
        } catch let error as MetadataProviderError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 30))
        } catch {
            XCTFail("erro inesperado: \(error)")
        }
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        Stub.handler = { _ in (200, [:], Data("{}".utf8)) }
        do {
            _ = try await makeProvider(key: "   ").search(MetadataQuery(categories: ["acao"], limit: 2))
            XCTFail("era esperado erro de credencial")
        } catch let error as MetadataProviderError {
            XCTAssertEqual(error, .missingCredential)
        } catch {
            XCTFail("erro inesperado: \(error)")
        }
        XCTAssertTrue(Stub.requestedURLs.isEmpty)
    }

    func testSearchMapsRealFieldsAndFiltersToPS4() async throws {
        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.rawgPayload) }
        let results = try await makeProvider().search(MetadataQuery(categories: ["acao"], limit: 3, excludedTitles: ["Bloodborne"]))
        XCTAssertEqual(results.count, 1, "Bloodborne já estava no catálogo e o duplicado interno deve ser descartado")
        let sekiro = try XCTUnwrap(results.first)
        XCTAssertEqual(sekiro.title, "Sekiro: Shadows Die Twice")
        XCTAssertEqual(sekiro.developer, "FromSoftware")
        XCTAssertNotNil(sekiro.releaseDate)
        XCTAssertTrue(sekiro.coverURLString.hasPrefix("https://"))
        XCTAssertTrue(sekiro.sourceURLString.contains("rawg.io"))
        XCTAssertTrue(sekiro.sizeText.isEmpty, "a RAWG não informa tamanho: o campo deve ficar vazio, nunca inventado")
        XCTAssertTrue(Stub.requestedURLs[0].query!.contains("platforms=18"))
    }

    func testSearchDropsDuplicatesInsideTheSameResultSet() async throws {
        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.rawgPayload) }
        let results = try await makeProvider().search(MetadataQuery(categories: ["acao"], limit: 5))
        let titles = results.map { TitleNormalizer.normalize($0.title) }
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    // MARK: - Assistant

    func testAssistantBuildsCandidateWithCategoriesAndSources() async throws {
        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.rawgPayload) }
        let outcome = try await makeAssistant().run(
            request: AutoCatalogRequest(categories: ["acao"], quantity: 3),
            existingGames: []
        )
        XCTAssertEqual(outcome.providerName, "RAWG")
        XCTAssertEqual(outcome.candidates.count, 2)
        let sekiro = try XCTUnwrap(outcome.candidates.first { $0.title.contains("Sekiro") })
        XCTAssertTrue(sekiro.categories.contains("acao"))
        XCTAssertEqual(sekiro.pkgStatus, .notProvided)
        XCTAssertFalse(sekiro.sources.isEmpty)
        XCTAssertFalse(sekiro.coverURLString.isEmpty)
        XCTAssertFalse(sekiro.bannerURLString.isEmpty)
    }

    func testAssistantSkipsGamesAlreadyInCatalog() async throws {
        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.rawgPayload) }
        var existing = GameDraft(); existing.name = "Sekiro: Shadows Die Twice"; existing.categories = ["acao"]
        existing.sizeText = "12 GB"
        let games = [existing.makeGame()]
        let outcome = try await makeAssistant().run(
            request: AutoCatalogRequest(categories: ["acao"], quantity: 5),
            existingGames: games
        )
        XCTAssertEqual(outcome.duplicatesSkipped, 2)
        XCTAssertEqual(outcome.candidates.map(\.title), ["Bloodborne"])
    }

    func testArtworkFlagRemovesImages() async throws {
        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.rawgPayload) }
        let outcome = try await makeAssistant().run(
            request: AutoCatalogRequest(categories: ["acao"], quantity: 3, extractArtwork: false),
            existingGames: []
        )
        XCTAssertTrue(outcome.candidates.allSatisfy { $0.coverURLString.isEmpty && $0.bannerURLString.isEmpty })
    }

    func testAdminSuppliedPKGLinkIsVerifiedNotInvented() async throws {
        let pkgURL = "https://cdn.example.com/pkg/bloodborne.pkg"
        Stub.handler = { request in
            if request.url?.host == "api.rawg.io" {
                return (200, ["Content-Type": "application/json"], self.rawgPayload)
            }
            return (200, ["Content-Type": "application/octet-stream", "Content-Length": "4294967296"], Data())
        }
        let outcome = try await makeAssistant().run(
            request: AutoCatalogRequest(categories: ["acao"], quantity: 3),
            existingGames: [],
            knownPKGLinks: [TitleNormalizer.normalize("Bloodborne"): pkgURL]
        )
        let bloodborne = try XCTUnwrap(outcome.candidates.first { $0.title == "Bloodborne" })
        XCTAssertEqual(bloodborne.downloadURLString, pkgURL)
        XCTAssertTrue(bloodborne.pkgStatus.isVerified, bloodborne.pkgStatus.detail)
        let sekiro = try XCTUnwrap(outcome.candidates.first { $0.title.contains("Sekiro") })
        XCTAssertEqual(sekiro.pkgStatus, .notProvided)
    }

    // MARK: - Link verification

    func testHTMLPageIsRejectedAsPKG() async {
        Stub.handler = { _ in (200, ["Content-Type": "text/html; charset=utf-8"], Data("<html></html>".utf8)) }
        let status = await PKGLinkVerifier(session: session).verify("https://example.com/jogo.pkg")
        XCTAssertFalse(status.isVerified)
        if case .rejected(let reason) = status {
            XCTAssertTrue(reason.contains("página"))
        } else {
            XCTFail("esperado .rejected, veio \(status)")
        }
    }

    func testMissingFileIsRejected() async {
        Stub.handler = { _ in (404, [:], Data()) }
        let status = await PKGLinkVerifier(session: session).verify("https://example.com/jogo.pkg")
        guard case .rejected(let reason) = status else { return XCTFail("esperado .rejected") }
        XCTAssertTrue(reason.contains("404"))
    }

    func testTinyBinaryIsRejected() async {
        Stub.handler = { _ in (200, ["Content-Type": "application/octet-stream", "Content-Length": "1024"], Data()) }
        let status = await PKGLinkVerifier(session: session).verify("https://example.com/jogo.pkg")
        XCTAssertFalse(status.isVerified)
    }

    func testNonHTTPSLinkIsRejectedWithoutRequest() async {
        let status = await PKGLinkVerifier(session: session).verify("http://example.com/jogo.pkg")
        XCTAssertFalse(status.isVerified)
        XCTAssertTrue(Stub.requestedURLs.isEmpty)
    }

    func testEmptyLinkIsNotProvided() async {
        let status = await PKGLinkVerifier(session: session).verify("  ")
        XCTAssertEqual(status, .notProvided)
    }

    // MARK: - Approval into the real catalog

    func testApprovalAddsToExistingCatalogAndBlocksDuplicates() async throws {
        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.rawgPayload) }
        let repository = CatalogRepository(fileURL: directory.appendingPathComponent("catalog.json"))
        let catalog = await CatalogStore(repository: repository)
        let assistantRepository = AutoCatalogRepository(fileURL: directory.appendingPathComponent("ai.json"))

        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.rawgPayload) }
        let provider = RAWGMetadataProvider(apiKey: "k", session: session)
        let outcome = try await AutoCatalogAssistant(provider: provider, verifier: PKGLinkVerifier(session: session))
            .run(request: AutoCatalogRequest(categories: ["acao"], quantity: 3), existingGames: [])
        var search = AutoCatalogSearch(request: AutoCatalogRequest(categories: ["acao"], quantity: 3), providerName: "RAWG")
        search.finishedAt = Date()
        // The provider returns no size (RAWG has none), so nothing is "ready" until the admin fills it.
        search.candidates = outcome.candidates.map { candidate in
            var updated = candidate
            updated.sizeText = "12.5 GB"
            return updated
        }
        assistantRepository.upsert(search)

        let store = await AutoCatalogStore(
            repository: assistantRepository,
            keyStore: InMemoryAPIKeyStore(value: "k"),
            catalog: catalog
        )

        let first = await store.approveAll(in: search.id)
        XCTAssertEqual(first.approved, 2)
        XCTAssertEqual(await catalog.games.count, 2)

        // Approving the same game again must not duplicate it.
        let second = await store.approveAll(in: search.id)
        XCTAssertEqual(second.approved, 0)
        XCTAssertEqual(await catalog.games.count, 2)

        let stored = try XCTUnwrap(await catalog.games.first { $0.name.contains("Sekiro") })
        XCTAssertEqual(stored.sizeText, "12.5 GB")
        XCTAssertEqual(stored.categories, ["acao"])
        XCTAssertEqual(stored.coverURLString, "https://media.rawg.io/media/games/sekiro.jpg")
        XCTAssertEqual(stored.platformTag, "PS4")
    }

    func testCandidateWithoutSizeIsNotReady() async {
        let candidate = CatalogCandidate(title: "Teste", categories: ["acao"], sizeText: "")
        XCTAssertFalse(candidate.isReady)
        XCTAssertTrue(candidate.blockingIssues().contains { $0.contains("Tamanho") })
    }

    func testCandidateWithUnverifiedLinkIsNotReady() async {
        var candidate = CatalogCandidate(title: "Teste", categories: ["acao"], sizeText: "10 GB")
        candidate.downloadURLString = "https://example.com/a.pkg"
        candidate.pkgStatus = .rejected("404")
        XCTAssertFalse(candidate.isReady)
    }

    // MARK: - Persistence of history

    func testHistoryIsPersistedAndCapped() throws {
        let url = directory.appendingPathComponent("history.json")
        let repository = AutoCatalogRepository(fileURL: url, maxSearches: 3)
        for index in 0..<5 {
            repository.upsert(AutoCatalogSearch(request: AutoCatalogRequest(categories: ["acao"], quantity: 1))
                .withProvider("run-\(index)"))
        }
        XCTAssertEqual(repository.searches.count, 3)
        let reopened = AutoCatalogRepository(fileURL: url, maxSearches: 3)
        XCTAssertEqual(reopened.searches.count, 3)
        XCTAssertEqual(reopened.searches.first?.providerName, "run-4")
    }

    func testRejectingCandidateKeepsItInHistory() async throws {
        let repository = AutoCatalogRepository(fileURL: directory.appendingPathComponent("reject.json"))
        var search = AutoCatalogSearch(request: AutoCatalogRequest(categories: ["acao"], quantity: 1))
        search.candidates = [CatalogCandidate(title: "A", categories: ["acao"], sizeText: "1 GB")]
        repository.upsert(search)
        let catalog = await CatalogStore(repository: CatalogRepository(fileURL: directory.appendingPathComponent("c2.json")))
        let store = await AutoCatalogStore(repository: repository, keyStore: InMemoryAPIKeyStore(), catalog: catalog)
        await store.reject(candidateID: search.candidates[0].id, in: search.id)
        let stored = await store.search(id: search.id)
        XCTAssertEqual(stored?.candidates.first?.state, .rejected)
        XCTAssertEqual(stored?.rejectedCount, 1)
    }
}

private extension AutoCatalogSearch {
    func withProvider(_ name: String) -> AutoCatalogSearch {
        var copy = self
        copy.providerName = name
        return copy
    }
}
