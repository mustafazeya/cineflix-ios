import SwiftUI

struct DetailView: View {
    let ref: MediaRef

    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(CatalogState.self) private var catalog
    @Environment(PlayerPresenter.self) private var presenter

    @State private var details: TitleDetails?
    @State private var error: String?
    @State private var season = 1
    @State private var episodes: [Episode] = []
    @State private var loadingEpisodes = false
    @State private var expanded = false

    var body: some View {
        ScrollView {
            if let d = details {
                content(d)
            } else if let error {
                EmptyState(title: "Couldn't load this title", message: error, systemImage: "exclamationmark.triangle")
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 260)
            }
        }
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ref) { await load() }
        .task { await catalog.refresh(settings) }
    }

    // MARK: Layout

    @ViewBuilder
    private func content(_ d: TitleDetails) -> some View {
        let item = d.item
        VStack(alignment: .leading, spacing: 0) {
            backdrop(d)

            VStack(alignment: .leading, spacing: 14) {
                Kicker(text: item.type == .tv ? "Series" : "Movie")

                Group {
                    if let logo = d.logoPath {
                        Artwork(url: TMDB.image(logo, "w500"))
                            .scaledToFit()
                            .frame(maxWidth: 280, maxHeight: 110, alignment: .leading)
                    } else {
                        Text(item.title)
                            .font(.cfLargeTitle)
                            .tracking(-0.8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                MetaLine(rating: item.rating, parts: metaParts(d), cert: d.certification)

                playButton(d)

                HStack {
                    ActionButton(title: "My List", systemImage: library.inMyList(ref) ? "checkmark" : "plus", active: library.inMyList(ref)) {
                        library.toggleMyList(item)
                    }
                    ActionButton(title: library.isWatched(ref) ? "Watched" : "Mark watched",
                                 systemImage: library.isWatched(ref) ? "checkmark.circle.fill" : "eye",
                                 active: library.isWatched(ref)) {
                        library.setWatched(item, !library.isWatched(ref))
                    }
                    if let key = d.trailerKey {
                        ActionButton(title: "Trailer", systemImage: "film") { presenter.playTrailer(key) }
                    }
                    ShareLink(item: URL(string: "https://www.themoviedb.org/\(ref.type.rawValue)/\(ref.id)")!) {
                        VStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 21)).frame(height: 24)
                            Text("Share").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Theme.text2)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)

                if let tagline = d.tagline {
                    Text(tagline).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                }
                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(3)
                        .lineLimit(expanded ? nil : 4)
                        .onTapGesture { withAnimation(.easeOut) { expanded.toggle() } }
                }
                if !d.genres.isEmpty {
                    Text(d.genres.map(\.name).joined(separator: " \u{00B7} "))
                        .font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
                if let credit = d.credit {
                    Text(credit).font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, -70)

            VStack(alignment: .leading, spacing: 28) {
                if item.type == .tv, !d.seasons.isEmpty { episodesSection(d) }
                if !d.cast.isEmpty { castRow(d) }
                if !d.recommendations.isEmpty { MediaRow(title: "More Like This", items: d.recommendations) }
            }
            .padding(.top, 30)
            .padding(.bottom, 40)
        }
    }

    private func backdrop(_ d: TitleDetails) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .overlay(Artwork(url: TMDB.image(d.item.backdropPath ?? d.item.posterPath, "w1280")))
            .clipped()
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: Theme.bg.opacity(0.7), location: 0.75),
                    .init(color: Theme.bg, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
    }

    private func metaParts(_ d: TitleDetails) -> [String] {
        var parts: [String] = []
        if let y = d.item.year { parts.append(y) }
        if d.item.type == .movie, let r = d.runtime, r > 0 { parts.append(r >= 60 ? "\(r / 60)h \(r % 60)m" : "\(r)m") }
        if d.item.type == .tv, d.numberOfSeasons > 0 { parts.append("\(d.numberOfSeasons) Season\(d.numberOfSeasons == 1 ? "" : "s")") }
        return parts
    }

    @ViewBuilder
    private func playButton(_ d: TitleDetails) -> some View {
        let available = catalog.has(ref)
        let progress = library.progress(for: ref)
        Button {
            play(d, progress: progress)
        } label: {
            Label(playLabel(d, progress: progress, available: available), systemImage: available == false ? "nosign" : "play.fill")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(available == false)
        .opacity(available == false ? 0.5 : 1)
    }

    private func playLabel(_ d: TitleDetails, progress: WatchProgress?, available: Bool?) -> String {
        if available == false { return "Not in your library" }
        if !settings.server.isConfigured { return "Set up streaming" }
        if let p = progress {
            if d.item.type == .tv, let s = p.season, let e = p.episode { return p.finished ? "Play Next Episode" : "Resume S\(s) E\(e)" }
            if p.position > 30 { return "Resume" }
        }
        if d.item.type == .tv { return "Play S\(d.seasons.first?.seasonNumber ?? 1) E1" }
        return "Play"
    }

    private func play(_ d: TitleDetails, progress: WatchProgress?) {
        let item = d.item
        if let p = progress {
            if p.finished, item.type == .tv, let s = p.season, let e = p.episode {
                Task {
                    if let next = await settings.tmdb.nextEpisode(showID: item.id, season: s, episode: e) {
                        presenter.play(request(d, season: next.season, episode: next.episode, resume: 0), settings: settings)
                    }
                }
                return
            }
            presenter.resume(p, settings: settings)
            return
        }
        if item.type == .tv {
            let first = d.seasons.first?.seasonNumber ?? 1
            Task {
                let eps = (try? await settings.tmdb.season(item.id, first)) ?? []
                if let ep = eps.first {
                    presenter.play(request(d, season: first, episode: ep, resume: 0), settings: settings)
                }
            }
        } else {
            presenter.play(PlaybackRequest(ref: ref, title: item.title, subtitle: metaParts(d).joined(separator: " \u{00B7} "),
                                           backdropPath: item.backdropPath, posterPath: item.posterPath, item: item),
                           settings: settings)
        }
    }

    private func request(_ d: TitleDetails, season: Int, episode: Episode, resume: Double) -> PlaybackRequest {
        PlaybackRequest(ref: ref, season: season, episode: episode.episodeNumber, title: d.item.title,
                        subtitle: episode.name, backdropPath: d.item.backdropPath, posterPath: d.item.posterPath,
                        stillPath: episode.stillPath, resume: resume, item: d.item)
    }

    // MARK: Episodes

    @ViewBuilder
    private func episodesSection(_ d: TitleDetails) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Menu {
                    Picker("Season", selection: $season) {
                        ForEach(d.seasons, id: \.seasonNumber) { s in
                            Text(s.name ?? "Season \(s.seasonNumber)").tag(s.seasonNumber)
                        }
                    }
                } label: {
                    Chip(title: d.seasons.first { $0.seasonNumber == season }?.name ?? "Season \(season)", active: false)
                }
                Spacer()
                if loadingEpisodes { ProgressView().tint(.white) }
            }
            .padding(.horizontal, 16)

            LazyVStack(spacing: 18) {
                ForEach(episodes) { ep in
                    EpisodeRow(show: d.item, season: season, episode: ep) {
                        let p = library.progress(for: ref)
                        let resume = (p?.season == season && p?.episode == ep.episodeNumber && p?.finished == false) ? (p?.position ?? 0) : 0
                        presenter.play(request(d, season: season, episode: ep, resume: resume), settings: settings)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .task(id: season) { await loadEpisodes(d) }
    }

    private func loadEpisodes(_ d: TitleDetails) async {
        loadingEpisodes = true
        episodes = (try? await settings.tmdb.season(d.item.id, season)) ?? []
        loadingEpisodes = false
    }

    private func castRow(_ d: TitleDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeader(title: "Cast")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(d.cast) { c in
                        NavigationLink(value: Route.person(id: c.id, name: c.name, type: d.item.type)) {
                            VStack(spacing: 6) {
                                Artwork(url: TMDB.image(c.profilePath, "w185"))
                                    .frame(width: 76, height: 76)
                                    .clipShape(Circle())
                                Text(c.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(c.character ?? "").font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1)
                            }
                            .frame(width: 84)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Data

    private func load() async {
        do {
            let d = try await settings.tmdb.details(ref)
            if let p = library.progress(for: ref), let s = p.season, d.seasons.contains(where: { $0.seasonNumber == s }) {
                season = s
            } else {
                season = d.seasons.first?.seasonNumber ?? 1
            }
            withAnimation(.easeOut(duration: 0.3)) { details = d }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct EpisodeRow: View {
    let show: MediaItem
    let season: Int
    let episode: Episode
    let onPlay: () -> Void
    @Environment(Library.self) private var library

    var body: some View {
        let watched = library.episodeWatched(show: show.id, season: season, episode: episode.episodeNumber)
        let p = library.progress(for: show.ref)
        let current = p?.season == season && p?.episode == episode.episodeNumber && p?.finished == false
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ArtworkBox(url: TMDB.image(episode.stillPath ?? show.backdropPath, "w300"), ratio: 16 / 9, corner: 5)
                        .frame(width: 136)
                        .overlay {
                            Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white)
                                .frame(width: 32, height: 32).background(.black.opacity(0.5), in: Circle())
                        }
                        .overlay(alignment: .bottom) {
                            if current, let p, p.fraction > 0 {
                                GeometryReader { g in
                                    Rectangle().fill(Theme.accent).frame(width: g.size.width * p.fraction)
                                }
                                .frame(height: 3)
                            }
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(episode.episodeNumber). \(episode.name ?? "Episode \(episode.episodeNumber)")")
                            .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        Text([episode.runtime.map { "\($0)m" }, episode.airDate].compactMap { $0 }.joined(separator: " \u{00B7} "))
                            .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                    Spacer(minLength: 0)
                    if watched {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.text2)
                    }
                }
                if let o = episode.overview, !o.isEmpty {
                    Text(o).font(.system(size: 13)).foregroundStyle(Theme.dim).lineLimit(3)
                }
            }
            .opacity(watched ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
