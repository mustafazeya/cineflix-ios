import SwiftUI

enum Route: Hashable {
    case title(MediaRef)
    case person(id: Int, name: String, type: MediaType)
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .title(let ref):
                DetailView(ref: ref)
            case .person(let id, let name, let type):
                BrowseView(initial: BrowseFilters(type: type, person: PersonFilter(id: id, name: name)))
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

    func playTrailer(_ key: String) { trailerKey = TrailerKey(id: key) }

    /// Resumes a Continue Watching entry: same movie/episode at the saved position.
    func resume(_ p: WatchProgress, settings: AppSettings) {
        play(PlaybackRequest(ref: p.ref, season: p.season, episode: p.episode, title: p.title, subtitle: p.subtitle,
                             backdropPath: p.backdropPath, posterPath: p.posterPath, stillPath: p.stillPath,
                             resume: p.finished ? 0 : p.position), settings: settings)
    }
}
