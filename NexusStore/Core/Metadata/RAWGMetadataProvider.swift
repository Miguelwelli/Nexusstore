import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Real metadata source: RAWG Video Games Database (https://rawg.io/apidocs).
///
/// Why RAWG: it is a documented public API with an official PS4 platform id, it returns covers and
/// screenshots over HTTPS, and it does not require a proxy for a mobile client. The API key is the
/// user's own free key, stored in the iOS Keychain and sent **only** to `api.rawg.io`.
///
/// Nothing here fabricates data: missing fields stay empty, and every candidate points back to the
/// RAWG page so the admin can verify it.
public struct RAWGMetadataProvider: MetadataProvider {

    public let displayName = "RAWG"

    /// RAWG's numeric id for the PlayStation 4 platform.
    public static let ps4PlatformID = 18

    private let apiKey: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.rawg.io/api")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Connection test

    public func testConnection() async throws -> TimeInterval {
        let start = Date()
        // Page size 1 keeps the probe cheap.
        _ = try await get(path: "/games", query: [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "page_size", value: "1")
        ])
        return Date().timeIntervalSince(start)
    }

    // MARK: - Search

    public func search(_ query: MetadataQuery) async throws -> MetadataSearchResult {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MetadataProviderError.missingCredential
        }
        let genres = Self.genreSlugs(for: query.categories)
        var collected: [MetadataCandidate] = []
        var seen = Set(query.excludedTitles.map(TitleNormalizer.normalize))
        // Distinct titles dropped as duplicates. A Set, not a counter: paging can return the same
        // title twice (the stubbed server always returns page 1) and it must count once.
        var skipped = Set<String>()
        var page = 1

        // Ask for a bit more than requested; duplicates against the catalog are dropped below.
        let wanted = max(query.limit, 1)
        while collected.count < wanted && page <= 3 {
            var items: [URLQueryItem] = [
                URLQueryItem(name: "key", value: apiKey),
                URLQueryItem(name: "platforms", value: String(Self.ps4PlatformID)),
                URLQueryItem(name: "page_size", value: String(max(wanted * 2, 10))),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "ordering", value: "-rating")
            ]
            if !genres.isEmpty {
                items.append(URLQueryItem(name: "genres", value: genres.joined(separator: ",")))
            }
            if !query.searchTerms.trimmingCharacters(in: .whitespaces).isEmpty {
                items.append(URLQueryItem(name: "search", value: query.searchTerms))
            }
            let json = try await get(path: "/games", query: items)
            guard let results = json["results"] as? [[String: Any]] else {
                throw MetadataProviderError.invalidResponse
            }
            if results.isEmpty { break }

            for result in results {
                guard let candidate = candidate(from: result) else { continue }
                let key = TitleNormalizer.normalize(candidate.title)
                guard !seen.contains(key) else {
                    skipped.insert(key)
                    continue
                }
                seen.insert(key)
                collected.append(candidate)
                if collected.count >= wanted { break }
            }
            page += 1
        }
        return MetadataSearchResult(items: Array(collected.prefix(wanted)), duplicatesSkipped: skipped.count)
    }

    // MARK: - Mapping

    private func candidate(from result: [String: Any]) -> MetadataCandidate? {
        guard let title = (result["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let slug = result["slug"] as? String else { return nil }

        let id = (result["id"] as? Int).map(String.init) ?? slug
        let background = (result["background_image"] as? String) ?? ""
        let extra = result["background_image_additional"] as? String ?? ""

        let genres = (result["genres"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let tags = (result["tags"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let platforms = (result["platforms"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
            guard let platform = entry["platform"] as? [String: Any],
                  let name = platform["name"] as? String else { return nil }
            return name
        }
        let stores = (result["stores"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
            guard let store = entry["store"] as? [String: Any],
                  let name = store["name"] as? String else { return nil }
            return name
        }

        // RAWG returns whole-number playtime/ratings only; the size of a PS4 package is not part of
        // its API, so `sizeText` stays empty on purpose. The admin fills it after checking the store.
        return MetadataCandidate(
            id: id,
            title: title,
            summary: Self.plainText(result["description_raw"] as? String ?? ""),
            releaseDate: Self.date(from: result["released"] as? String),
            genres: genres,
            coverURLString: Self.https(background),
            bannerURLString: Self.https(extra),
            platforms: platforms.isEmpty ? ["PlayStation 4"] : platforms,
            sizeText: "",
            version: "",
            developer: Self.firstName(result["developers"]),
            publisher: Self.firstName(result["publishers"]),
            ageRating: "",
            tags: Array(tags.prefix(6)) + stores.map { "Loja: \($0)" },
            rating: result["rating"] as? Double ?? 0,
            ratingCount: result["ratings_count"] as? Int ?? 0,
            sourceName: "RAWG (\(stores.first ?? "rawg.io"))",
            sourceURLString: "https://rawg.io/games/\(slug)"
        )
    }

    // MARK: - Helpers

    private func get(path: String, query: [URLQueryItem]) async throws -> [String: Any] {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        guard let url = components.url else { throw MetadataProviderError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MetadataProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MetadataProviderError.invalidResponse }
        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw MetadataProviderError.unauthorized
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw MetadataProviderError.rateLimited(retryAfter: retry)
        default:
            throw MetadataProviderError.server(status: http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetadataProviderError.invalidResponse
        }
        return json
    }

    private static func https(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if raw.hasPrefix("https://") { return raw }
        if raw.hasPrefix("http://") { return "https://" + raw.dropFirst("http://".count) }
        return ""
    }

    private static func firstName(_ value: Any?) -> String {
        guard let list = value as? [[String: Any]], let first = list.first else { return "" }
        return first["name"] as? String ?? ""
    }

    private static func date(from raw: String?) -> Date? {
        guard let raw, raw.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    /// RAWG descriptions are plain text already; strip residual BBCode-ish markup and collapse spaces.
    private static func plainText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased, accent-free, punctuation-free title used for duplicate detection.
    static func normalizedTitle(_ raw: String) -> String { TitleNormalizer.normalize(raw) }

    /// Maps Nexus Store category raw values to RAWG genre slugs.
    public static func genreSlugs(for categories: [String]) -> [String] {
        var slugs: [String] = []
        for category in categories {
            switch category {
            case "acao": slugs.append(contentsOf: ["action"])
            case "aventura": slugs.append(contentsOf: ["adventure"])
            case "rpg": slugs.append(contentsOf: ["rpg"])
            case "tiro": slugs.append(contentsOf: ["shooter"])
            case "mundo-aberto": slugs.append(contentsOf: ["open-world"])
            case "esportes": slugs.append(contentsOf: ["sports"])
            case "corrida": slugs.append(contentsOf: ["racing"])
            case "terror": slugs.append(contentsOf: ["horror"])
            case "estrategia": slugs.append(contentsOf: ["strategy"])
            case "simulacao": slugs.append(contentsOf: ["simulation"])
            case "luta": slugs.append(contentsOf: ["fighting"])
            case "familia": slugs.append(contentsOf: ["family", "puzzle"])
            case "soulslike": slugs.append(contentsOf: ["action", "rpg"])
            default: break
            }
        }
        return Array(Set(slugs)).sorted()
    }
}
