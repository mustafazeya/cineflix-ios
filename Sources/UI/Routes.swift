import SwiftUI

enum Route: Hashable {
    case title(MediaRef)
    case person(id: Int, name: String, type: MediaType)
    case mega(videoID: String, folder: String?)
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .title(let ref):
                DetailView(ref: ref)
            case .person(let id, let name, let type):
                BrowseView(initial: BrowseFilters(type: type, person: PersonFilter(id: id, name: name)))
            case .mega(let videoID, let folder):
                MegaFolderView(videoID: videoID, folder: folder)
            }
        }
    }
}

/// What the player screen should play. Identifiable so it can drive a full-screen cover.
struct PlaybackRequest: Identifiable, Hashable {
    let id = UUID()
    var ref: MediaRef
    var season: Int?
    var episode: Int?
    var title: String
    var subtitle: String?
    var backdropPath: String?
    var posterPath: String?
    var stillPath: String?
    var resume: Double = 0
    var item: MediaItem?
    /// Set for a video saved under My Videos. It has no TMDB title, so no progress or subtitle search.
    var link: URL?
    /// Set for a file inside a MEGA link.
    var mega: MegaPlay?

    var isCustom: Bool { link != nil || mega != nil }
}

nonisolated struct MegaPlay: Hashable, Sendable {
    var linkText: String
    var node: String
}

/// Opens the player from anywhere (hero, details, Continue Watching).
@Observable
final class PlayerPresenter {
    var current: PlaybackRequest?
    var trailerKey: TrailerKey?
    var needsSetup = false

    struct TrailerKey: Identifiable, Hashable { let id: String }

    func play(_ request: PlaybackRequest, settings: AppSettings) {
        if settings.server.isConfigured { current = request } else { needsSetup = true }
    }

    /// Plays a saved link. It does not need the media server to be set up.
    func playLink(_ video: SavedVideo) {
        guard let url = URL(string: video.url) else { return }
        current = PlaybackRequest(ref: MediaRef(type: .movie, id: 0), title: video.name, subtitle: video.host, link: url)
    }

    func playMega(_ video: SavedVideo, node: MegaNode, folder: MegaFolder) {
        let parent = node.parent.isEmpty ? [] : folder.path(to: node.parent)
        let subtitle = ([video.name] + parent).joined(separator: " \u{00B7} ")
        current = PlaybackRequest(ref: MediaRef(type: .movie, id: 0), title: (node.name as NSString).deletingPathExtension,
                                  subtitle: subtitle, mega: MegaPlay(linkText: video.url, node: node.id))
    }

    func playTrailer(_ key: String) { trailerKey = TrailerKey(id: key) }

    /// Resumes a Continue Watching entry: same movie/episode at the saved position.
    func resume(_ p: WatchProgress, settings: AppSettings) {
        play(PlaybackRequest(ref: p.ref, season: p.season, episode: p.episode, title: p.title, subtitle: p.subtitle,
                             backdropPath: p.backdropPath, posterPath: p.posterPath, stillPath: p.stillPath,
                             resume: p.finished ? 0 : p.position), settings: settings)
    }
}
