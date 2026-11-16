import SwiftUI

struct HomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(CatalogState.self) private var catalog
    @Environment(PlayerPresenter.self) private var presenter

    @State private var hero: [MediaItem] = []
    @State private var reloadID = UUID()
    @State private var detail: MediaRef?
    @State private var cast = CastManager.shared

    var body: some View {
        let tmdb = settings.tmdb
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                HeroCarousel(items: hero, onDetails: { detail = $0 })

                ContinueWatchingRow()

                if !catalog.recent.isEmpty {
                    LoadingRow(title: "Recently Added to Your Library") {
                        try await withThrowingTaskGroup(of: (Int, MediaItem?).self) { group in
                            for (i, e) in catalog.recent.prefix(20).enumerated() {
                                group.addTask { (i, try? await tmdb.details(e.ref).item) }
                            }
                            var out: [(Int, MediaItem)] = []
                            for try await (i, item) in group { if let item { out.append((i, item)) } }
                            return out.sorted { $0.0 < $1.0 }.map(\.1)
                        }
                    }
                }

                if settings.kidsPolicy != nil {
                    kidsRows(tmdb)
                } else {
                    LoadingRow(title: "Top 10 Today", style: .top10) { try await tmdb.trending(nil) }
                    LoadingRow(title: "New Releases", style: .landscape) { try await tmdb.list(.movie, "now_playing").items }
                    LoadingRow(title: "Popular Movies") { try await tmdb.list(.movie, "popular").items }
                    LoadingRow(title: "Popular TV Shows", style: .landscape) { try await tmdb.list(.tv, "popular").items }
                    becauseYouWatched
                    LoadingRow(title: "New Episodes This Week") { try await tmdb.list(.tv, "on_the_air").items }
                    LoadingRow(title: "Top Rated Movies", style: .landscape) { try await tmdb.list(.movie, "top_rated").items }
                    LoadingRow(title: "Top Rated TV Shows") { try await tmdb.list(.tv, "top_rated").items }
                    LoadingRow(title: "Coming Soon", style: .landscape) { try await tmdb.list(.movie, "upcoming").items }
                    ForEach(Array(Self.genres.enumerated()), id: \.offset) { i, g in
                        LoadingRow(title: g.1, style: i % 2 == 0 ? .poster : .landscape) {
                            try await tmdb.discover(.movie, ["with_genres": String(g.0)]).items
                        }
                    }
                }
            }
            .padding(.bottom, 40)
            .id(reloadID)
        }
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topTrailing) {
            if cast.hasDevices || cast.hasSession {
                PlayerControl { CastButton() }
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                    .accessibilityLabel("Cast")
            }
        }
        .navigationDestination(item: $detail) { DetailView(ref: $0) }
        .refreshable {
            await ResponseCache.shared.clear()
            await catalog.refresh(settings, force: true)
            await loadHero()
            reloadID = UUID()
        }
        .task(id: settings.tmdbToken) { await loadHero() }
    }


    /// Up to two rows based on what was thumbed up or watched. They sit among the main rows, so they only load when scrolled near.
    @ViewBuilder private var becauseYouWatched: some View {
        ForEach(library.recommendationSeeds(limit: 2), id: \.ref) { seed in
            BecauseYouWatchedRow(seed: seed)
        }
    }

    /// Home for a kids profile. The catalog client already limits every list to what the profile may see; these queries start from
    /// the family and animation catalogue so the rows are not mostly filtered away.
    @ViewBuilder private func kidsRows(_ tmdb: TMDB) -> some View {
        LoadingRow(title: "Popular Movies") { try await tmdb.discover(.movie, [:]).items }
        LoadingRow(title: "Popular TV Shows", style: .landscape) { try await tmdb.discover(.tv, [:]).items }
        becauseYouWatched
        LoadingRow(title: "New Releases", style: .landscape) {
            try await tmdb.discover(.movie, ["sort_by": "primary_release_date.desc", "primary_release_date.lte": TMDB.today, "vote_count.gte": "20"]).items
        }
        LoadingRow(title: "Animation") { try await tmdb.discover(.movie, ["with_genres": String(KidsPolicy.Genre.animation)]).items }
        LoadingRow(title: "Kids TV", style: .landscape) { try await tmdb.discover(.tv, ["with_genres": String(KidsPolicy.Genre.kids)]).items }
        LoadingRow(title: "Family Movies") { try await tmdb.discover(.movie, ["with_genres": String(KidsPolicy.Genre.family)]).items }
        LoadingRow(title: "Top Rated Movies", style: .landscape) {
            try await tmdb.discover(.movie, ["sort_by": "vote_average.desc", "vote_count.gte": "500"]).items
        }
    }

    private static let genres: [(Int, String)] = [(28, "Action"), (35, "Comedy"), (18, "Drama"), (53, "Thrillers"), (878, "Sci-Fi")]

    private func loadHero() async {
        // A kids profile's hero comes from its own kid-safe list, never from trending.
        let tmdb = settings.tmdb
        let items = (try? await (tmdb.kids == nil ? tmdb.trending(nil) : tmdb.discover(.movie, [:]).items)) ?? []
        hero = Array(items.filter { $0.backdropPath != nil }.prefix(6))
    }
}

// MARK: - Because you watched

private struct BecauseYouWatchedRow: View {
    let seed: MediaItem
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @State private var items: [MediaItem]?

    var body: some View {
        // Titles already watched or thumbed down are left out when shown, so the row follows later changes without reloading.
        let shown = (items ?? []).filter { $0.ref != seed.ref && !library.isWatched($0.ref) && library.rating(for: $0.ref) >= 0 }
        Group {
            if items == nil {
                SkeletonRow()
            } else if !shown.isEmpty {
                MediaRow(title: "Because you watched \(seed.title)", items: shown)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("because-\(seed.ref.key)")
        .task(id: LoadKey(ref: seed.ref, policy: settings.kidsPolicy)) {
            let loaded = await settings.tmdb.recommendations(seed.ref)
            if !Task.isCancelled { items = loaded }
        }
    }

    private struct LoadKey: Hashable { let ref: MediaRef; let policy: KidsPolicy? }
}

// MARK: - Hero

struct HeroCarousel: View {
    let items: [MediaItem]
    var onDetails: (MediaRef) -> Void = { _ in }
    @State private var page: MediaRef?

    var body: some View {
        ZStack(alignment: .top) {
            if items.isEmpty {
                Theme.surface.frame(height: 560)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(items, id: \.ref) { item in
                            HeroPage(item: item, onDetails: { onDetails(item.ref) }).containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $page)
                .frame(height: 560)
                .overlay(alignment: .bottom) {
                    HStack(spacing: 6) {
                        ForEach(items, id: \.ref) { item in
                            Capsule()
                                .fill(item.ref == (page ?? items.first?.ref) ? .white : .white.opacity(0.3))
                                .frame(width: item.ref == (page ?? items.first?.ref) ? 18 : 6, height: 6)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: page)
                    .padding(.bottom, 2)
                }
            }

            HStack {
                Image("Wordmark").resizable().scaledToFit().frame(height: 24)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 58)
        }
    }
}

private struct HeroPage: View {
    let item: MediaItem
    let onDetails: () -> Void
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(CatalogState.self) private var catalog
    @Environment(PlayerPresenter.self) private var presenter
    @State private var logo: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 560)
                // The artwork is wider than the screen. Clipping hides the overflow but it would still catch touches
                // meant for the buttons on the neighbouring pages, so it must not take part in hit testing.
                .overlay(Artwork(url: TMDB.image(item.backdropPath, "w1280")).allowsHitTesting(false))
                .clipped()
                .overlay {
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.55), location: 0),
                        .init(color: .clear, location: 0.22),
                        .init(color: .clear, location: 0.42),
                        .init(color: Theme.bg.opacity(0.85), location: 0.75),
                        .init(color: Theme.bg, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }

            VStack(spacing: 12) {
                NavigationLink(value: Route.title(item.ref)) {
                    Group {
                        if let logo {
                            Artwork(url: TMDB.image(logo, "w500"))
                                .scaledToFit()
                                .frame(maxWidth: 260, maxHeight: 96)
                        } else {
                            Text(item.title)
                                .font(.system(size: 34, weight: .heavy))
                                .tracking(-0.6)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                    }
                    .frame(height: 96)
                }
                .buttonStyle(.plain)

                MetaLine(rating: item.rating, parts: [item.year].compactMap { $0 } + catalog.genres(item, max: 2))

                HStack(spacing: 10) {
                    Button(action: play) {
                        Label(playLabel, systemImage: "play.fill")
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button {
                        library.toggleMyList(item)
                    } label: {
                        Label("My List", systemImage: library.inMyList(item.ref) ? "checkmark" : "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.glass)
                    .sensoryFeedback(.success, trigger: library.inMyList(item.ref))

                    Button(action: onDetails) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 50, height: 50)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Details")
                    .accessibilityIdentifier("hero-details")
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 26)
        }
        .task { logo = await settings.tmdb.logo(item.ref) }
    }

    // Play, or Resume when the title is in Continue Watching: the same wording as its details page.
    private var progress: WatchProgress? { library.resumable(item.ref) }

    private var playLabel: String {
        guard let p = progress else { return "Play" }
        if item.type == .tv, let s = p.season, let e = p.episode { return p.finished ? "Play Next Episode" : "Resume S\(s) E\(e)" }
        return "Resume"
    }

    private func play() {
        if let p = progress {
            if p.finished, item.type == .tv, let s = p.season, let e = p.episode {
                Task {
                    guard let next = await settings.tmdb.nextEpisode(showID: item.id, season: s, episode: e) else { return }
                    presenter.play(PlaybackRequest(ref: item.ref, season: next.season, episode: next.episode.episodeNumber, title: item.title,
                                                   subtitle: next.episode.name, backdropPath: item.backdropPath, posterPath: item.posterPath,
                                                   stillPath: next.episode.stillPath, item: item), settings: settings)
                }
                return
            }
            presenter.resume(p, settings: settings)
            return
        }
        presenter.play(PlaybackRequest(ref: item.ref, season: item.type == .tv ? 1 : nil, episode: item.type == .tv ? 1 : nil,
                                       title: item.title, backdropPath: item.backdropPath, posterPath: item.posterPath, item: item),
                       settings: settings)
    }
}
