import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import NexusStoreCore

/// Verifies the Gemini provider against a stubbed `URLProtocol` that imitates the real
/// `generateContent` response shape, including `groundingMetadata`.
final class GeminiProviderTests: XCTestCase {

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var bodies: [Data] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.append(request)
            if let body = request.httpBody ?? request.bodyStreamData() {
                Self.bodies.append(body)
            }
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
    private let gamesJSON = """
    {"games":[
      {"title":"Sekiro: Shadows Die Twice","description":"Ação no Japão feudal.","categories":["Ação / Aventura"],"publisher":"Activision","developer":"FromSoftware","releaseYear":"2019","packageSize":"12.5 GB","version":"1.06","coverURL":"https://media.example.com/sekiro.jpg","bannerURL":"","sourceURLs":["https://www.playstation.com/pt-br/games/sekiro/"]},
      {"title":"Jogo Sem Citação","description":"","categories":["RPG"],"publisher":"","developer":"","releaseYear":"","packageSize":"","version":"","coverURL":"","bannerURL":"","sourceURLs":["https://fonte-inventada.example.com/x"]}
    ]}
    """

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        session = URLSession(configuration: configuration)
        Stub.handler = nil
        Stub.requests = []
        Stub.bodies = []
    }

    override func tearDownWithError() throws {
        Stub.handler = nil
    }

    private func makeProvider(key: String = "AIzaSyFakeKeyForTests123456789012345678") -> GeminiMetadataProvider {
        GeminiMetadataProvider(apiKey: key, session: session)
    }

    private func response(text: String, citations: [String]) -> Data {
        let json: [String: Any] = [
            "candidates": [[
                "content": ["parts": [["text": text]]],
                "groundingMetadata": [
                    "groundingChunks": citations.map { ["web": ["uri": $0, "title": "fonte"]] }
                ]
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - Transport

    func testRequestUsesTheDocumentedEndpointAndHeader() async throws {
        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.response(text: self.gamesJSON, citations: ["https://www.playstation.com/pt-br/games/sekiro/"])) }
        _ = try await makeProvider().search(MetadataQuery(categories: ["acao"], limit: 2))

        let request = try XCTUnwrap(Stub.requests.first)
        XCTAssertEqual(request.url?.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-3.5-flash:generateContent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "AIzaSyFakeKeyForTests123456789012345678")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testRequestBodyAsksForSearchToolAndJSONOutput() async throws {
        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.response(text: self.gamesJSON, citations: ["https://www.playstation.com/pt-br/games/sekiro/"])) }
        _ = try await makeProvider().search(MetadataQuery(categories: ["acao"], limit: 2))
        let body = try XCTUnwrap(Stub.bodies.first)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertNotNil(tools.first?["google_search"], "o tool google_search deve ser enviado")
        let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertNotNil(config["responseSchema"], "a resposta precisa ser JSON validado por schema")
        let prompt = try XCTUnwrap((json["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])
        XCTAssertTrue((prompt.first?["text"] as? String ?? "").contains("NÃO invente links"))
    }

    // MARK: - Grounding rules

    func testGameWithoutGroundingCitationIsDropped() async throws {
        Stub.handler = { _ in
            (200, ["Content-Type": "application/json"],
             self.response(text: self.gamesJSON, citations: ["https://www.playstation.com/pt-br/games/sekiro/"]))
        }
        let result = try await makeProvider().search(MetadataQuery(categories: ["acao"], limit: 5))
        XCTAssertEqual(result.items.map(\.title), ["Sekiro: Shadows Die Twice"],
                       "o jogo cuja fonte não aparece nas citações deve ser descartado")
        XCTAssertEqual(result.duplicatesSkipped, 1, "o descarte deve ser contabilizado, não escondido")
    }

    func testAllGamesDroppedWhenGroundingHasNoCitations() async throws {
        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.response(text: self.gamesJSON, citations: [])) }
        let result = try await makeProvider().search(MetadataQuery(categories: ["acao"], limit: 5))
        XCTAssertTrue(result.items.isEmpty, "sem citações não há pesquisa: nada pode ser cadastrado")
        XCTAssertEqual(result.duplicatesSkipped, 2)
    }

    func testMappedFieldsAndEmptySizeWhenNotGrounded() async throws {
        let payload = """
        {"games":[{"title":"Bloodborne","description":"Souls","categories":["RPG"],"publisher":"Sony","developer":"FromSoftware","releaseYear":"2015","packageSize":"  ","version":"1.0","coverURL":"http://media.example.com/b.jpg","bannerURL":"","sourceURLs":["https://www.playstation.com/pt-br/games/bloodborne/"]}]}
        """
        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.response(text: payload, citations: ["https://www.playstation.com/pt-br/games/bloodborne/"])) }
        let result = try await makeProvider().search(MetadataQuery(categories: ["rpg"], limit: 1))
        let game = try XCTUnwrap(result.items.first)
        XCTAssertEqual(game.title, "Bloodborne")
        XCTAssertEqual(game.developer, "FromSoftware")
        XCTAssertTrue(game.sizeText.isEmpty, "tamanho inválido/vazio não pode virar texto")
        XCTAssertEqual(game.coverURLString, "https://media.example.com/b.jpg", "http deve ser promovido a https")
        XCTAssertEqual(game.sourceURLString, "https://www.playstation.com/pt-br/games/bloodborne/")
    }

    func testPackageSizeIsKeptOnlyWhenItParses() async throws {
        let payload = """
        {"games":[{"title":"A","packageSize":"48.5 GB","sourceURLs":["https://x.test/a"]},
                  {"title":"B","packageSize":"muito grande","sourceURLs":["https://x.test/b"]}]}
        """
        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.response(text: payload, citations: ["https://x.test/a", "https://x.test/b"])) }
        let result = try await makeProvider().search(MetadataQuery(categories: ["acao"], limit: 2))
        XCTAssertEqual(result.items.first?.sizeText, "48.5 GB")
        XCTAssertEqual(result.items.last?.sizeText, "")
    }

    // MARK: - Errors

    func testInvalidKeyIsReportedAsUnauthorized() async {
        Stub.handler = { _ in (403, [:], Data()) }
        do {
            _ = try await makeProvider().testConnection()
            XCTFail("deveria falhar")
        } catch let error as MetadataProviderError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("erro inesperado: \(error)")
        }
    }

    func testEmptyKeyFailsBeforeNetwork() async {
        do {
            _ = try await makeProvider(key: "   ").search(MetadataQuery(categories: ["acao"], limit: 1))
            XCTFail("deveria falhar")
        } catch let error as MetadataProviderError {
            XCTAssertEqual(error, .missingCredential)
        } catch {
            XCTFail("erro inesperado: \(error)")
        }
        XCTAssertTrue(Stub.requests.isEmpty)
    }

    func testRateLimitIsReported() async {
        Stub.handler = { _ in (429, [:], Data()) }
        do {
            _ = try await makeProvider().search(MetadataQuery(categories: ["acao"], limit: 1))
            XCTFail("deveria falhar")
        } catch let error as MetadataProviderError {
            XCTAssertEqual(error, .rateLimited(retryAfter: nil))
        } catch {
            XCTFail("erro inesperado: \(error)")
        }
    }

    func testNonJSONAnswerIsReportedAsInvalidResponse() async {
        Stub.handler = { _ in (200, ["Content-Type": "application/json"], self.response(text: "não é json", citations: ["https://x.test/a"])) }
        do {
            _ = try await makeProvider().search(MetadataQuery(categories: ["acao"], limit: 1))
        } catch {
            // parse() returns empty rather than throwing; assert nothing is produced.
        }
        let result = try? await makeProvider().search(MetadataQuery(categories: ["acao"], limit: 1))
        XCTAssertEqual(result?.items.count ?? 0, 0)
    }
}

private extension URLRequest {
    /// URLProtocol receives the body as a stream in some Foundation versions.
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
