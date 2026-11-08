import Foundation

enum StreamType: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto, page, video

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Detect automatically"
        case .page: "Web page with its own player"
        case .video: "Video file / HLS stream"
        }
    }
}

enum Playback: Sendable {
    case video(URL)
    case page(URL)
}

enum ServerError: LocalizedError {
    case notConfigured
    case notAvailable
    case http(Int)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Set your Stream URL in Settings to play titles."
        case .notAvailable: "This title isn't available on your server."
        case .http(let code): "Your server returned an error (\(code))."
        case .unreachable: "Your server didn't respond."
        }
    }
}

struct CatalogEntry: Codable, Hashable, Sendable {
    let tmdbId: Int
    let type: MediaType
    let addedAt: String?

    var ref: MediaRef { MediaRef(type: type, id: tmdbId) }
}

/// Client for the user's own licensed media server.
/// Stream URL: {base}/movie/{tmdbId} and {base}/tv/{tmdbId}/{season}/{episode} return a video or a player page.
/// Catalog (optional): {catalogBase or base}/catalog returns {"items":[{tmdbId,type,addedAt}]}.
struct MediaServer: Sendable {
    let streamBase: String
    let catalogBase: String
    let token: String
    let streamType: StreamType

    var isConfigured: Bool { !streamBase.isEmpty }

    private func trimmed(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func origin(_ s: String) -> String? {
        guard let u = URL(string: trimmed(s)), let scheme = u.scheme, let host = u.host() else { return nil }
        return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
    }

    /// Media elements can't send headers, so the token goes in the query for our own servers only.
    private func withToken(_ url: URL) -> URL {
        guard !token.isEmpty else { return url }
        let ours = [origin(streamBase), origin(catalogBase)].compactMap { $0 }
        guard ours.contains(where: { url.absoluteString.hasPrefix($0) }),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
        return comps.url ?? url
    }

    func streamURL(_ ref: MediaRef, season: Int?, episode: Int?) -> URL? {
        let base = trimmed(streamBase)
        guard !base.isEmpty else { return nil }
        let path = ref.type == .tv ? "/tv/\(ref.id)/\(season ?? 1)/\(episode ?? 1)" : "/movie/\(ref.id)"
        return URL(string: base + path).map(withToken)
    }

    func resolve(_ ref: MediaRef, season: Int?, episode: Int?) async throws -> Playback {
        guard let url = streamURL(ref, season: season, episode: episode) else { throw ServerError.notConfigured }
        switch streamType {
        case .page: return .page(url)
        case .video: return .video(url)
        case .auto: return try await probe(url)
        }
    }

    /// A link saved under My Videos: a video file, an HLS stream, or a page with its own player.
    /// The server token is only ever sent to the user's own server, never to other hosts.
    func resolveLink(_ link: URL) async throws -> Playback {
        let url = withToken(link)
        if ["m3u8", "mp4", "m4v", "mov"].contains(link.pathExtension.lowercased()) { return .video(url) }
        return try await probe(url, authorized: url != link)
    }

    /// Reads only the response headers (and a few bytes if needed) to tell a video from a web page.
    private func probe(_ url: URL, authorized: Bool = true) async throws -> Playback {
        var req = URLRequest(url: url, timeoutInterval: 10)
        if authorized, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let bytes: URLSession.AsyncBytes
        let resp: URLResponse
        do {
            (bytes, resp) = try await URLSession.shared.bytes(for: req)
        } catch {
            // Network limits on the probe: let the player try the URL directly.
            return url.pathExtension.lowercased() == "m3u8" ? .video(url) : .page(url)
        }
        defer { bytes.task.cancel() }
        guard let http = resp as? HTTPURLResponse else { return .video(url) }
        if http.statusCode == 404 { throw ServerError.notAvailable }
        guard (200..<400).contains(http.statusCode) else { throw ServerError.http(http.statusCode) }

        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let final = http.url ?? url
        if type.contains("mpegurl") || final.pathExtension.lowercased() == "m3u8" { return .video(url) }
        if type.hasPrefix("video/") || type.hasPrefix("audio/") || type.contains("octet-stream") || type.contains("mp2t") { return .video(url) }
        if type.contains("html") { return .page(url) }

        var head = [UInt8]()
        for try await b in bytes {
            head.append(b)
            if head.count >= 7 { break }
        }
        return String(decoding: head, as: UTF8.self) == "#EXTM3U" ? .video(url) : .page(url)
    }

    /// nil when the server has no catalog (404, not JSON, unreachable).
    func catalog() async -> [CatalogEntry]? {
        let base = trimmed(catalogBase.isEmpty ? streamBase : catalogBase)
        guard !base.isEmpty, let url = URL(string: base + "/catalog") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json")
        else { return nil }

        struct Wrapped: Decodable { let items: [CatalogEntry] }
        let dec = JSONDecoder()
        let items = (try? dec.decode(Wrapped.self, from: data).items) ?? (try? dec.decode([CatalogEntry].self, from: data))
        return items.map { $0.sorted { ($0.addedAt ?? "") > ($1.addedAt ?? "") } }
    }
}
