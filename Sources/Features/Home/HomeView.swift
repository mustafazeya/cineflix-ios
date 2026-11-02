import SwiftUI

struct HomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(CatalogState.self) private var catalog
    @Environment(PlayerPresenter.self) private var presenter

    @State private var hero: [MediaItem] = []
    @State private var reloadID = UUID()

    var body: some View {
        let tmdb = settings.tmdb
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                HeroCarousel(items: hero)

                if !library.continueWatching.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        RowHeader(title: "Continue Watching")
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 10) {
                                ForEach(library.continueWatching, id: \.ref) { p in
                                    Button { presenter.resume(p, settings: settings) } label: { ContinueCard(progress: p) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            NavigationLink(value: Route.title(p.ref)) { Label("Details", systemImage: "info.circle") }
                                        }
                                }
                            }
                        }
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .scrollIndicators(.hidden)
                    }
                }

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

                LoadingRow(title: "Top 10 Today", style: .top10) { try await tmdb.trending(nil) }
                LoadingRow(title: "New Releases", style: .landscape) { try await tmdb.list(.movie, "now_playing").items }
                LoadingRow(title: "Popular Movies") { try await tmdb.list(.movie, "popular").items }
                LoadingRow(title: "Popular TV Shows", style: .landscape) { try await tmdb.list(.tv, "popular").items }
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
            .padding(.bottom, 40)
            .id(reloadID)
        }
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            await ResponseCache.shared.clear()
            await catalog.refresh(settings, force: true)
            await loadHero()
            reloadID = UUID()
        }
        .task(id: settings.tmdbToken) { await loadHero() }
    }

    private static let genres: [(Int, String)] = [(28, "Action"), (35, "Comedy"), (18, "Drama"), (53, "Thrillers"), (878, "Sci-Fi")]

    private func loadHero() async {
        let items = (try? await settings.tmdb.trending(nil)) ?? []
        hero = Array(items.filter { $0.backdropPath != nil }.prefix(6))
    }
}

// MARK: - Hero

struct HeroCarousel: View {
    let items: [MediaItem]
    @State private var page: MediaRef?

    var body: some View {
        ZStack(alignment: .top) {
            if items.isEmpty {
                Theme.surface.frame(height: 560)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(items, id: \.ref) { item in
                            HeroPage(item: item).containerRelativeFrame(.horizontal)
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
                .overlay(Artwork(url: TMDB.image(item.backdropPath, "w1280")))
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
                    Button {
                        presenter.play(PlaybackRequest(ref: item.ref, season: item.type == .tv ? 1 : nil, episode: item.type == .tv ? 1 : nil,
                                                       title: item.title, backdropPath: item.backdropPath, posterPath: item.posterPath, item: item),
                                       settings: settings)
                    } label: {
                        Label("Play", systemImage: "play.fill")
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
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 26)
        }
        .task { logo = await settings.tmdb.logo(item.ref) }
    }
}
