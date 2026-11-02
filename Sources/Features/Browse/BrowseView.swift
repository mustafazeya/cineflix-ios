import SwiftUI

struct PersonFilter: Hashable {
    let id: Int
    let name: String
}

enum BrowseSort: String, CaseIterable, Identifiable {
    case popular, top, newest, votes
    var id: String { rawValue }
    var label: String {
        switch self {
        case .popular: "Most popular"
        case .top: "Top rated"
        case .newest: "Newest"
        case .votes: "Most voted"
        }
    }
}

struct BrowseFilters: Hashable {
    var type: MediaType = .movie
    var sort: BrowseSort = .popular
    var genre: Genre?
    var year: String = ""
    var person: PersonFilter?
    var minRating: Double = 0

    var isDefault: Bool { sort == .popular && genre == nil && year.isEmpty && person == nil && minRating == 0 }

    static let years: [String] = {
        let current = Calendar.current.component(.year, from: Date())
        return (2000...current).reversed().map(String.init) + ["1990s", "1980s", "1970s", "1960s", "1950s", "Before 1950"]
    }()

    var yearRange: (String, String)? {
        if year.isEmpty { return nil }
        if year == "Before 1950" { return ("1800-01-01", "1949-12-31") }
        if year.hasSuffix("s"), let d = Int(year.dropLast()) { return ("\(d)-01-01", "\(d + 9)-12-31") }
        return ("\(year)-01-01", "\(year)-12-31")
    }
}

struct BrowseView: View {
    var initial: BrowseFilters?

    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library

    @State private var filters = BrowseFilters()
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var genres: [Genre] = []
    @State private var showActor = false
    @State private var generation = 0
    @State private var started = false

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Type", selection: $filters.type) {
                    Text("Movies").tag(MediaType.movie)
                    Text("TV Shows").tag(MediaType.tv)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                filterBar

                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 16)

                if items.isEmpty && !loading && page > 0 {
                    EmptyState(title: "Nothing matches", message: "Try removing a filter.", systemImage: "line.3.horizontal.decrease")
                } else {
                    PosterGrid(items: items) { i in
                        if i >= items.count - 9 { Task { await loadMore() } }
                    }
                }
                if loading { ProgressView().tint(.white).frame(maxWidth: .infinity).padding() }
            }
            .padding(.vertical, 8)
        }
        .background(Theme.bg)
        .navigationTitle(initial?.person?.name ?? "Browse")
        .toolbarTitleDisplayMode(initial == nil ? .large : .inline)
        .sheet(isPresented: $showActor) {
            ActorPicker(selected: filters.person) { filters.person = $0 }
        }
        .task {
            guard !started else { return }
            started = true
            if let initial { filters = initial }
            await reload()
        }
        .onChange(of: filters) { _, new in
            Task {
                if genres.isEmpty || new.genre == nil { genres = (try? await settings.tmdb.genres(new.type)) ?? [] }
                await reload()
            }
        }
        .onChange(of: filters.type) { filters.genre = nil }
        .onChange(of: settings.hideWatched) { Task { await reload() } }
        .task(id: filters.type) { genres = (try? await settings.tmdb.genres(filters.type)) ?? [] }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Sort", selection: $filters.sort) {
                        ForEach(BrowseSort.allCases) { Text($0.label).tag($0) }
                    }
                } label: { Chip(title: filters.sort.label, active: filters.sort != .popular) }

                Menu {
                    Picker("Genre", selection: $filters.genre) {
                        Text("All genres").tag(Genre?.none)
                        ForEach(genres) { Text($0.name).tag(Genre?.some($0)) }
                    }
                } label: { Chip(title: filters.genre?.name ?? "All genres", active: filters.genre != nil) }

                Menu {
                    Picker("Year", selection: $filters.year) {
                        Text("Any year").tag("")
                        ForEach(BrowseFilters.years, id: \.self) { Text($0).tag($0) }
                    }
                } label: { Chip(title: filters.year.isEmpty ? "Any year" : filters.year, active: !filters.year.isEmpty) }

                Button { showActor = true } label: {
                    Chip(title: filters.person?.name ?? "Any actor", active: filters.person != nil)
                }
                .buttonStyle(.plain)

                Menu {
                    Picker("Rating", selection: $filters.minRating) {
                        Text("Any rating").tag(0.0)
                        ForEach([8.0, 7.0, 6.0, 5.0], id: \.self) { Text("\(Int($0))+").tag($0) }
                    }
                } label: { Chip(title: filters.minRating > 0 ? "Rating \(Int(filters.minRating))+" : "Any rating", active: filters.minRating > 0) }

                Button { settings.hideWatched.toggle() } label: {
                    Chip(title: settings.hideWatched ? "Hiding watched" : "Showing watched", active: settings.hideWatched, showsMenu: false)
                }
                .buttonStyle(.plain)

                if !filters.isDefault {
                    Button {
                        let type = filters.type
                        filters = BrowseFilters(type: type)
                    } label: {
                        Label("Clear", systemImage: "xmark").font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text2)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private var summary: String {
        var parts = ["\(filters.sort.label) \(filters.type == .movie ? "movies" : "TV shows")"]
        if let g = filters.genre { parts.append(g.name) }
        if !filters.year.isEmpty { parts.append(filters.year) }
        if let p = filters.person { parts.append("with \(p.name)") }
        if filters.minRating > 0 { parts.append("rated \(Int(filters.minRating))+") }
        if settings.hideWatched { parts.append("watched hidden") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Loading

    private func reload() async {
        generation += 1
        items = []
        page = 0
        totalPages = 1
        loading = false
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, page < totalPages, page < 25 else { return }
        loading = true
        let gen = generation
        let next = page + 1
        let result = try? await fetch(page: next)
        guard gen == generation else { return }
        loading = false
        page = next
        guard let result else { return }
        totalPages = min(result.totalPages, 500)
        let seen = Set(items.map(\.ref))
        let fresh = result.items.filter { !seen.contains($0.ref) && !(settings.hideWatched && library.isWatched($0.ref)) }
        items += fresh
        // Pages emptied by "hide watched": keep fetching so the grid isn't blank.
        if items.count < 21, !result.items.isEmpty, page < totalPages, page < 10 { await loadMore() }
    }

    private func fetch(page: Int) async throws -> ItemPage {
        let f = filters
        let tmdb = settings.tmdb
        // TMDB can't filter TV discover by cast, so TV + actor uses the person's credits.
        if let person = f.person, f.type == .tv {
            var list = try await tmdb.personCredits(person.id, .tv)
            var seen = Set<Int>()
            list = list.filter { i in
                guard i.posterPath != nil, seen.insert(i.id).inserted else { return false }
                if let g = f.genre, !i.genreIDs.contains(g.id) { return false }
                if f.minRating > 0, i.voteAverage < f.minRating { return false }
                if let r = f.yearRange { guard let d = i.date, d >= r.0, d <= r.1 else { return false } }
                if f.sort == .top, i.voteCount < 20 { return false }
                return true
            }
            func weight(_ i: MediaItem) -> Double { log(2 + Double(max(i.episodeCount, 1))) }
            list.sort {
                switch f.sort {
                case .newest: ($0.date ?? "") > ($1.date ?? "")
                case .top: $0.voteAverage > $1.voteAverage
                case .votes: $0.voteCount > $1.voteCount
                case .popular: $0.popularity * weight($0) * weight($0) > $1.popularity * weight($1) * weight($1)
                }
            }
            let start = (page - 1) * 20
            let slice = start < list.count ? Array(list[start..<min(start + 20, list.count)]) : []
            return ItemPage(items: slice, totalPages: max(1, (list.count + 19) / 20))
        }

        let movie = f.type == .movie
        let dateKey = movie ? "primary_release_date" : "first_air_date"
        var p: [String: String] = ["page": String(page)]
        switch f.sort {
        case .popular: p["sort_by"] = "popularity.desc"
        case .top: p["sort_by"] = "vote_average.desc"
        case .newest: p["sort_by"] = "\(dateKey).desc"
        case .votes: p["sort_by"] = "vote_count.desc"
        }
        // "Top rated" needs a vote floor so niche titles with a few perfect votes don't win.
        let narrow = f.person != nil || !f.year.isEmpty || f.genre != nil
        if f.sort == .top {
            p["vote_count.gte"] = f.person != nil ? "50" : (movie ? (narrow ? "800" : "5000") : (narrow ? "200" : "1000"))
        } else {
            p["vote_count.gte"] = f.person != nil ? "0" : (f.sort == .newest ? "10" : "50")
        }
        if let g = f.genre { p["with_genres"] = String(g.id) }
        if f.minRating > 0 { p["vote_average.gte"] = String(f.minRating) }
        if let r = f.yearRange {
            p["\(dateKey).gte"] = r.0
            p["\(dateKey).lte"] = r.1
        }
        if f.sort == .newest, (f.yearRange?.1 ?? "9999") > TMDB.today { p["\(dateKey).lte"] = TMDB.today }
        if let person = f.person { p["with_cast"] = String(person.id) }
        return try await tmdb.discover(f.type, p)
    }
}

// MARK: - Actor picker

private struct ActorPicker: View {
    let selected: PersonFilter?
    let onPick: (PersonFilter?) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var people: [Person] = []

    var body: some View {
        NavigationStack {
            List {
                Button { onPick(nil); dismiss() } label: {
                    HStack {
                        Text("Any actor")
                        Spacer()
                        if selected == nil { Image(systemName: "checkmark") }
                    }
                }
                ForEach(people) { p in
                    Button {
                        onPick(PersonFilter(id: p.id, name: p.name))
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Artwork(url: TMDB.image(p.profilePath, "w185")).frame(width: 44, height: 44).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundStyle(.white)
                                if !p.knownFor.isEmpty {
                                    Text(p.knownFor).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                                }
                            }
                            Spacer()
                            if selected?.id == p.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Actor")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search by name")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                if q.isEmpty {
                    people = (try? await settings.tmdb.popularPeople()) ?? []
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                people = ((try? await settings.tmdb.searchPeople(q)) ?? []).filter { $0.profilePath != nil || $0.department == "Acting" }
            }
        }
        .presentationDetents([.large])
    }
}
