import Foundation
import Observation

/// User settings. Values saved in the app always win over the bundled defaults (Info.plist / Secrets.xcconfig).
@Observable
final class AppSettings {
    static let defaultTrailerPage = "https://www.zeyamustafa.online/movies/trailer.html"

    private let defaults = UserDefaults.standard
    private static let bundledToken = (Bundle.main.object(forInfoDictionaryKey: "TMDBToken") as? String) ?? ""
    private static let bundledSubDL = (Bundle.main.object(forInfoDictionaryKey: "SubDLKey") as? String) ?? ""

    var tmdbToken: String { didSet { save("tmdbToken", tmdbToken) } }
    var language: String { didSet { save("language", language) } }
    var region: String { didSet { save("region", region) } }
    var streamBase: String { didSet { save("streamBase", streamBase) } }
    var catalogBase: String { didSet { save("catalogBase", catalogBase) } }
    var serverToken: String { didSet { save("serverToken", serverToken) } }
    var streamType: StreamType { didSet { save("streamType", streamType.rawValue) } }
    var trailerPage: String { didSet { save("trailerPage", trailerPage) } }
    var subdlKey: String { didSet { save("subdlKey", subdlKey) } }
    var subLangs: String { didSet { save("subLangs", subLangs) } }
    var hideWatched: Bool { didSet { defaults.set(hideWatched, forKey: "cf.hideWatched") } }

    init() {
        let defaults = UserDefaults.standard
        func value(_ key: String, _ fallback: String) -> String { defaults.string(forKey: "cf." + key) ?? fallback }
        tmdbToken = value("tmdbToken", Self.bundledToken)
        language = value("language", "en-US")
        region = value("region", "")
        streamBase = value("streamBase", "")
        catalogBase = value("catalogBase", "")
        serverToken = value("serverToken", "")
        streamType = StreamType(rawValue: value("streamType", "auto")) ?? .auto
        trailerPage = value("trailerPage", Self.defaultTrailerPage)
        subdlKey = value("subdlKey", Self.bundledSubDL)
        subLangs = value("subLangs", "EN")
        hideWatched = defaults.object(forKey: "cf.hideWatched") as? Bool ?? true
    }

    private func save(_ key: String, _ value: String) { defaults.set(value, forKey: "cf." + key) }

    var tmdb: TMDB { TMDB(token: tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines), language: language, region: region) }
    var server: MediaServer { MediaServer(streamBase: streamBase, catalogBase: catalogBase, token: serverToken, streamType: streamType) }
    var hasTMDB: Bool { !tmdbToken.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasSubDL: Bool { !subdlKey.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Availability from the media server's optional /catalog, plus genre names for meta lines.
@Observable
final class CatalogState {
    private(set) var available: Set<String>?
    private(set) var recent: [CatalogEntry] = []
    private(set) var genreNames: [Int: String] = [:]
    private var lastRefresh: Date?

    /// true / false when the server publishes a catalog, nil when unknown.
    func has(_ ref: MediaRef) -> Bool? {
        available.map { $0.contains(ref.key) }
    }

    func refresh(_ settings: AppSettings, force: Bool = false) async {
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < 600 { return }
        lastRefresh = Date()
        if let items = await settings.server.catalog() {
            available = Set(items.map(\.ref.key))
            recent = items
        } else {
            available = nil
            recent = []
        }
    }

    func loadGenres(_ tmdb: TMDB) async {
        guard genreNames.isEmpty else { return }
        async let m = try? tmdb.genres(.movie)
        async let t = try? tmdb.genres(.tv)
        var map: [Int: String] = [:]
        for g in (await m ?? []) + (await t ?? []) { map[g.id] = g.name }
        genreNames = map
    }

    func genres(_ item: MediaItem, max: Int = 3) -> [String] {
        Array(item.genreIDs.compactMap { genreNames[$0] }.prefix(max))
    }
}
