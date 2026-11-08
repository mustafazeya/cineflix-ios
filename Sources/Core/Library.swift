import Foundation
import Observation

struct SavedItem: Codable, Hashable, Sendable {
    var item: MediaItem
    var date: Date
}

/// A link saved by hand under My Videos.
struct SavedVideo: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var url: String
    var date: Date
    /// "mega" for a MEGA folder or file link; nil for a direct link.
    var type: String?

    var isMega: Bool { type == "mega" || MegaLink.parse(url) != nil }

    var host: String {
        URL(string: url)?.host() ?? url
    }
}

struct WatchProgress: Codable, Hashable, Sendable {
    var ref: MediaRef
    var season: Int?
    var episode: Int?
    var position: Double
    var duration: Double
    var title: String
    var subtitle: String?
    var backdropPath: String?
    var posterPath: String?
    var stillPath: String?
    var updatedAt: Date
    var finished: Bool

    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
}

/// My List, Already Watched, watch progress and finished episodes. Stored as JSON in Application Support.
/// Guest use (no account) has one file. While signed in, each profile has its own file, so profiles never mix.
@Observable
final class Library {
    private(set) var myList: [SavedItem] = []
    private(set) var watched: [String: SavedItem] = [:]
    private(set) var progress: [String: WatchProgress] = [:]
    private(set) var episodesWatched: Set<String> = []
    private(set) var videos: [SavedVideo] = []

    /// nil = guest data, otherwise the signed-in profile whose file is loaded.
    private(set) var namespace: String?

    /// Called for every local edit, so the sync layer can send it. Not called for changes that came from sync.
    @ObservationIgnored var onChange: ((SyncChange) -> Void)?

    fileprivate struct Snapshot: Codable {
        var myList: [SavedItem]
        var watched: [String: SavedItem]
        var progress: [String: WatchProgress]
        var episodesWatched: Set<String>
        var videos: [SavedVideo]?
    }

    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    fileprivate static func fileURL(_ namespace: String?) -> URL {
        directory.appendingPathComponent(namespace.map { "library-\($0).json" } ?? "library.json")
    }

    private var fileURL: URL { Self.fileURL(namespace) }

    init(namespace: String? = nil) {
        // UI tests pass -cf.resetLibrary YES to start from an empty library.
        if UserDefaults.standard.bool(forKey: "cf.resetLibrary") { try? FileManager.default.removeItem(at: Self.fileURL(nil)) }
        // Remove data left by the former "My Videos" feature.
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("custom-videos.json"))
        self.namespace = namespace
        load()
    }

    private func load() {
        myList = []; watched = [:]; progress = [:]; episodesWatched = []; videos = []
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        myList = s.myList
        watched = s.watched
        progress = s.progress
        episodesWatched = s.episodesWatched
        videos = s.videos ?? []
    }

    private func persist() {
        let s = Snapshot(myList: myList, watched: watched, progress: progress, episodesWatched: episodesWatched, videos: videos)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Switches between guest data (nil) and a profile's data.
    func useNamespace(_ id: String?) {
        guard id != namespace else { return }
        persist()
        namespace = id
        load()
    }

    /// Deletes a profile's local copy (signing out of a shared phone, or deleting the profile).
    static func removeData(for profile: String) { try? FileManager.default.removeItem(at: fileURL(profile)) }

    private func emit(_ kind: String, _ key: String, _ value: JSONValue?, deleted: Bool = false, at date: Date = Date()) {
        onChange?(SyncChange(kind: kind, key: key, value: value, updatedAt: date.timeIntervalSince1970 * 1000, deleted: deleted))
    }

    // MARK: My List

    func inMyList(_ ref: MediaRef) -> Bool { myList.contains { $0.item.ref == ref } }

    @discardableResult
    func toggleMyList(_ item: MediaItem) -> Bool {
        if let i = myList.firstIndex(where: { $0.item.ref == item.ref }) {
            myList.remove(at: i)
            persist()
            emit("list", item.ref.key, nil, deleted: true)
            return false
        }
        let entry = SavedItem(item: item, date: Date())
        myList.insert(entry, at: 0)
        persist()
        emit("list", item.ref.key, Self.listJSON(entry), at: entry.date)
        return true
    }

    // MARK: My Videos

    /// Adds a video, or changes the one with this id.
    @discardableResult
    func saveVideo(id: String? = nil, name: String, url: String, type: String? = nil) -> SavedVideo {
        let existing = id.flatMap { id in videos.first { $0.id == id } }
        let entry = SavedVideo(id: id ?? Self.newVideoID(), name: name, url: url, date: existing?.date ?? Date(), type: type)
        if let i = videos.firstIndex(where: { $0.id == entry.id }) { videos[i] = entry } else { videos.insert(entry, at: 0) }
        persist()
        emit("video", entry.id, Self.videoJSON(entry), at: Date())
        return entry
    }

    func removeVideo(_ id: String) {
        videos.removeAll { $0.id == id }
        persist()
        emit("video", id, nil, deleted: true)
    }

    private static func newVideoID() -> String {
        "v" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(UInt32.random(in: 0..<1_679_616), radix: 36)
    }

    // MARK: Watched

    func isWatched(_ ref: MediaRef) -> Bool { watched[ref.key] != nil }

    var watchedItems: [MediaItem] { watched.values.sorted { $0.date > $1.date }.map(\.item) }

    func setWatched(_ item: MediaItem, _ on: Bool) {
        if on {
            let entry = SavedItem(item: item, date: Date())
            watched[item.ref.key] = entry
            let hadProgress = progress[item.ref.key] != nil
            progress[item.ref.key] = nil
            persist()
            if hadProgress { emit("progress", item.ref.key, nil, deleted: true) }
            emit("watched", item.ref.key, Self.watchedJSON(entry), at: entry.date)
        } else {
            watched[item.ref.key] = nil
            persist()
            emit("watched", item.ref.key, nil, deleted: true)
        }
    }

    func episodeWatched(show: Int, season: Int, episode: Int) -> Bool {
        episodesWatched.contains("\(show):\(season):\(episode)")
    }

    // MARK: Progress

    func progress(for ref: MediaRef) -> WatchProgress? { progress[ref.key] }

    var continueWatching: [WatchProgress] {
        progress.values
            .filter { $0.position > 30 || $0.ref.type == .tv || $0.duration == 0 }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Records progress. Finishing a movie (>95%) moves it to Already Watched; finished episodes get a check mark.
    func record(_ p: WatchProgress, item: MediaItem? = nil) {
        var p = p
        p.updatedAt = Date()
        p.finished = p.duration > 0 && p.position / p.duration > 0.95
        var out: [(String, String, JSONValue?, Bool)] = []
        if p.finished, p.ref.type == .tv, let s = p.season, let e = p.episode {
            let key = "\(p.ref.id):\(s):\(e)"
            episodesWatched.insert(key)
            out.append(("episode", "tv:" + key, .number(p.updatedAt.timeIntervalSince1970 * 1000), false))
        }
        if p.finished, p.ref.type == .movie {
            progress[p.ref.key] = nil
            let it = item ?? MediaItem(id: p.ref.id, type: .movie, title: p.title, posterPath: p.posterPath, backdropPath: p.backdropPath)
            let entry = SavedItem(item: it, date: Date())
            watched[p.ref.key] = entry
            out.append(("progress", p.ref.key, nil, true))
            out.append(("watched", p.ref.key, Self.watchedJSON(entry), false))
        } else {
            progress[p.ref.key] = p
            out.append(("progress", p.ref.key, Self.progressJSON(p), false))
        }
        persist()
        out.forEach { emit($0.0, $0.1, $0.2, deleted: $0.3) }
    }

    func clearHistory() {
        let keys = Array(progress.keys)
        let episodes = Array(episodesWatched)
        progress.removeAll()
        episodesWatched.removeAll()
        persist()
        keys.forEach { emit("progress", $0, nil, deleted: true) }
        episodes.forEach { emit("episode", "tv:" + $0, nil, deleted: true) }
    }
}

// MARK: - Sync format (the same shapes the TV app uses)

extension Library {
    private static func ms(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded() }
    private static func date(_ ms: Double?) -> Date { Date(timeIntervalSince1970: (ms ?? Date().timeIntervalSince1970 * 1000) / 1000) }

    fileprivate static func itemJSON(_ i: MediaItem, extra: [(String, JSONValue?)]) -> JSONValue {
        [String: JSONValue].compacting([
            ("id", .number(Double(i.id))), ("media_type", .string(i.type.rawValue)), ("title", .string(i.title)),
            ("poster_path", .text(i.posterPath)), ("backdrop_path", .text(i.backdropPath)),
            ("vote_average", i.voteAverage > 0 ? .number(i.voteAverage) : nil), ("release_date", .text(i.date))
        ] + extra)
    }

    fileprivate static func listJSON(_ s: SavedItem) -> JSONValue { itemJSON(s.item, extra: [("addedAt", .number(ms(s.date)))]) }

    fileprivate static func watchedJSON(_ s: SavedItem) -> JSONValue {
        itemJSON(s.item, extra: [("genre_ids", s.item.genreIDs.isEmpty ? nil : .array(s.item.genreIDs.map { .number(Double($0)) })), ("watchedAt", .number(ms(s.date)))])
    }

    fileprivate static func progressJSON(_ p: WatchProgress) -> JSONValue {
        [String: JSONValue].compacting([
            ("type", .string(p.ref.type.rawValue)), ("id", .number(Double(p.ref.id))), ("season", .num(p.season)), ("episode", .num(p.episode)),
            ("position", .number(p.position)), ("duration", .number(p.duration)), ("title", .string(p.title)), ("subtitle", .text(p.subtitle)),
            ("backdrop_path", .text(p.backdropPath)), ("poster_path", .text(p.posterPath)), ("still_path", .text(p.stillPath)),
            ("updatedAt", .number(ms(p.updatedAt))), ("finished", .bool(p.finished))
        ])
    }

    fileprivate static func videoJSON(_ v: SavedVideo) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(v.id), "name": .string(v.name), "url": .string(v.url), "addedAt": .number(ms(v.date))]
        if v.type == "mega" { o["type"] = .string("mega") }
        return .object(o)
    }

    private static func video(from j: JSONValue, fallback: Double) -> SavedVideo? {
        guard let id = j["id"]?.string, let name = j["name"]?.string, let url = j["url"]?.string else { return nil }
        return SavedVideo(id: id, name: name, url: url, date: date(j["addedAt"]?.double ?? fallback), type: j["type"]?.string)
    }

    private static func item(from j: JSONValue) -> MediaItem? {
        guard let id = j["id"]?.int, let t = j["media_type"]?.string, let type = MediaType(rawValue: t) else { return nil }
        return MediaItem(id: id, type: type, title: j["title"]?.string ?? "", posterPath: j["poster_path"]?.string, backdropPath: j["backdrop_path"]?.string,
                         voteAverage: j["vote_average"]?.double ?? 0, date: j["release_date"]?.string,
                         genreIDs: j["genre_ids"]?.array?.compactMap { $0.int } ?? [])
    }

    private static func progress(from j: JSONValue) -> WatchProgress? {
        guard let id = j["id"]?.int, let t = j["type"]?.string, let type = MediaType(rawValue: t) else { return nil }
        return WatchProgress(ref: MediaRef(type: type, id: id), season: j["season"]?.int, episode: j["episode"]?.int,
                             position: j["position"]?.double ?? 0, duration: j["duration"]?.double ?? 0, title: j["title"]?.string ?? "",
                             subtitle: j["subtitle"]?.string, backdropPath: j["backdrop_path"]?.string, posterPath: j["poster_path"]?.string,
                             stillPath: j["still_path"]?.string, updatedAt: date(j["updatedAt"]?.double), finished: j["finished"]?.bool ?? false)
    }

    /// Applies a change that came from another device. It is not reported through `onChange`, so it is not sent back.
    func apply(_ changes: [SyncChange]) {
        guard !changes.isEmpty else { return }
        changes.forEach(applyOne)
        persist()
    }

    private func applyOne(_ c: SyncChange) {
        switch c.kind {
        case "list":
            myList.removeAll { $0.item.ref.key == c.key }
            if !c.deleted, let v = c.value, let item = Self.item(from: v) {
                myList.append(SavedItem(item: item, date: Self.date(v["addedAt"]?.double ?? c.updatedAt)))
                myList.sort { $0.date > $1.date }
            }
        case "video":
            videos.removeAll { $0.id == c.key }
            if !c.deleted, let v = c.value, let video = Self.video(from: v, fallback: c.updatedAt) {
                videos.append(video)
                videos.sort { $0.date > $1.date }
            }
        case "watched":
            if c.deleted { watched[c.key] = nil }
            else if let v = c.value, let item = Self.item(from: v) { watched[c.key] = SavedItem(item: item, date: Self.date(v["watchedAt"]?.double ?? c.updatedAt)) }
        case "progress":
            if c.deleted { progress[c.key] = nil }
            else if let v = c.value, let p = Self.progress(from: v) { progress[c.key] = p }
        case "episode":
            let key = c.key.hasPrefix("tv:") ? String(c.key.dropFirst(3)) : c.key
            if c.deleted { episodesWatched.remove(key) } else { episodesWatched.insert(key) }
        default: break
        }
    }

    /// Everything in one namespace as sync changes (used to upload guest data to a profile).
    static func export(namespace: String?) -> [SyncChange] {
        guard let data = try? Data(contentsOf: fileURL(namespace)), let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return [] }
        var out: [SyncChange] = []
        s.myList.forEach { out.append(SyncChange(kind: "list", key: $0.item.ref.key, value: listJSON($0), updatedAt: ms($0.date))) }
        (s.videos ?? []).forEach { out.append(SyncChange(kind: "video", key: $0.id, value: videoJSON($0), updatedAt: ms($0.date))) }
        s.watched.forEach { out.append(SyncChange(kind: "watched", key: $0.key, value: watchedJSON($0.value), updatedAt: ms($0.value.date))) }
        s.progress.forEach { out.append(SyncChange(kind: "progress", key: $0.key, value: progressJSON($0.value), updatedAt: ms($0.value.updatedAt))) }
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        s.episodesWatched.forEach { out.append(SyncChange(kind: "episode", key: "tv:" + $0, value: .number(now), updatedAt: now)) }
        return out
    }
}
