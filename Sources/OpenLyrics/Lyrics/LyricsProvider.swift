import Foundation

/// Network tuning for lyrics lookups.
enum LyricsNetworkConfig {
    /// Seconds one request may take before it's abandoned. Sane range: 4–15.
    static let requestTimeout: TimeInterval = 8
    /// Identifies OpenLyrics to LRCLIB, which asks clients to name themselves.
    static let userAgent = "OpenLyrics/\(AppInfo.version) (https://github.com/Ayanprakash35/OpenLyrics)"
}

enum LyricsProviderID: String, CaseIterable, Codable, Sendable {
    case lrclib, netease

    var displayName: String {
        switch self {
        case .lrclib: "LRCLIB"
        case .netease: "NetEase Cloud Music"
        }
    }
}

/// What one provider found.
struct ProviderMatch: Sendable {
    var lyrics: Lyrics
    /// `TrackMatcher` score of the result the lyrics came from, 0...1.
    var confidence: Double
}

enum ProviderError: Error, Equatable {
    /// The provider couldn't be reached or answered with an error: try again later.
    case unreachable
    /// The provider answered with something unreadable.
    case badResponse
}

/// A source of lyrics. Returns nil when the provider answered but has nothing for the track.
protocol LyricsProvider: Sendable {
    var id: LyricsProviderID { get }
    func lyrics(for query: TrackQuery) async throws(ProviderError) -> ProviderMatch?
}

/// GET requests with a shared ephemeral session: no cookies, no disk cache.
enum HTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = LyricsNetworkConfig.requestTimeout
        configuration.timeoutIntervalForResource = LyricsNetworkConfig.requestTimeout * 2
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// The body and status of a GET. Throws `.unreachable` for transport failures and 5xx.
    static func get(_ url: URL, headers: [String: String] = [:]) async throws(ProviderError) -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw .badResponse }
        if (500..<600).contains(http.statusCode) || http.statusCode == 429 { throw .unreachable }
        return (data, http.statusCode)
    }

    static func url(_ base: String, _ items: [(String, String?)]) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = items.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        return components?.url
    }
}
