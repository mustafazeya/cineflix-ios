import Foundation
import Observation

struct SavedItem: Codable, Hashable, Sendable {
    var item: MediaItem
    var date: Date
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
@Observable
final class Library {
    private(set) var myList: [SavedItem] = []
    private(set) var watched: [String: SavedItem] = [:]
    private(set) var progress: [String: WatchProgress] = [:]
    private(set) var episodesWatched: Set<String> = []

    private struct Snapshot: Codable {
        var myList: [SavedItem]
        var watched: [String: SavedItem]
        var progress: [String: WatchProgress]
        var episodesWatched: Set<String>
    }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }()

    init() {
        // UI tests pass -cf.resetLibrary YES to start from an empty library.
        if UserDefaults.standard.bool(forKey: "cf.resetLibrary") { try? FileManager.default.removeItem(at: fileURL) }
        // Remove data left by the former "My Videos" feature.
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent().appendingPathComponent("custom-videos.json"))
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        myList = s.myList
        watched = s.watched
        progress = s.progress
        episodesWatched = s.episodesWatched
    }

    private func persist() {
        let s = Snapshot(myList: myList, watched: watched, progress: progress, episodesWatched: episodesWatched)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: My List

    func inMyList(_ ref: MediaRef) -> Bool { myList.contains { $0.item.ref == ref } }

    @discardableResult
    func toggleMyList(_ item: MediaItem) -> Bool {
        if let i = myList.firstIndex(where: { $0.item.ref == item.ref }) {
            myList.remove(at: i)
            persist()
            return false
        }
        myList.insert(SavedItem(item: item, date: Date()), at: 0)
        persist()
        return true
    }

    // MARK: Watched

    func isWatched(_ ref: MediaRef) -> Bool { watched[ref.key] != nil }

    var watchedItems: [MediaItem] { watched.values.sorted { $0.date > $1.date }.map(\.item) }

    func setWatched(_ item: MediaItem, _ on: Bool) {
        if on {
            watched[item.ref.key] = SavedItem(item: item, date: Date())
            progress[item.ref.key] = nil
        } else {
            watched[item.ref.key] = nil
        }
        persist()
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
        if p.finished, p.ref.type == .tv, let s = p.season, let e = p.episode {
            episodesWatched.insert("\(p.ref.id):\(s):\(e)")
        }
        if p.finished, p.ref.type == .movie {
            progress[p.ref.key] = nil
            let it = item ?? MediaItem(id: p.ref.id, type: .movie, title: p.title, posterPath: p.posterPath, backdropPath: p.backdropPath)
            watched[p.ref.key] = SavedItem(item: it, date: Date())
        } else {
            progress[p.ref.key] = p
        }
        persist()
    }

    func clearHistory() {
        progress.removeAll()
        episodesWatched.removeAll()
        persist()
    }
}
