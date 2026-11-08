import SwiftUI

struct SearchView: View {
    /// Kept by the root view so the query survives switching tabs.
    @Binding var query: String
    @Environment(AppSettings.self) private var settings
    @State private var results: [MediaItem] = []
    @State private var trending: [MediaItem] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            content
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, shows")
                .withRoutes()
        }
    }

    private var content: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if q.isEmpty {
                    Kicker(text: "Trending this week").padding(.horizontal, 16)
                    PosterGrid(items: trending)
                } else if results.isEmpty && !searching {
                    EmptyState(title: "No results", message: "Nothing found for \"\(q)\".", systemImage: "magnifyingglass")
                } else {
                    PosterGrid(items: results)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Theme.bg)
        .navigationTitle("Search")
        .task { trending = (try? await settings.tmdb.trending(nil, week: true)) ?? [] }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { results = []; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            results = (try? await settings.tmdb.search(q)) ?? []
            searching = false
        }
    }
}

struct MyStuffView: View {
    enum Section: String, CaseIterable { case list = "My List", watched = "Watched", videos = "Videos" }

    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(PlayerPresenter.self) private var presenter
    @State private var section: Section = .list
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AccountCard()

                if !library.continueWatching.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        RowHeader(title: "Continue Watching")
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 10) {
                                ForEach(library.continueWatching, id: \.ref) { p in
                                    Button { presenter.resume(p, settings: settings) } label: { ContinueCard(progress: p, width: 220) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .scrollIndicators(.hidden)
                    }
                }

                Picker("Section", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                switch section {
                case .list:
                    if library.myList.isEmpty {
                        EmptyState(title: "Your list is empty", message: "Tap My List on any title to save it here.", systemImage: "plus.circle")
                    } else {
                        PosterGrid(items: library.myList.map(\.item))
                    }
                case .watched:
                    if library.watchedItems.isEmpty {
                        EmptyState(title: "Nothing watched yet",
                                   message: "Finished movies appear here automatically, or tap Mark watched on any title.",
                                   systemImage: "checkmark.circle")
                    } else {
                        PosterGrid(items: library.watchedItems)
                    }
                case .videos:
                    VideosSection()
                }
            }
            .padding(.vertical, 8)
        }
        .background(Theme.bg)
        .navigationTitle("My Stuff")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
    }
}

struct SettingsView: View {
    var reason: String?

    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(CatalogState.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var status = ""
    @State private var testing = false
    @State private var confirmClear = false

    var body: some View {
        @Bindable var s = settings
        Form {
            if let reason {
                Section { Text(reason).foregroundStyle(Theme.text2) }
            }
            Section {
                TextField("https://stream.example.com", text: $s.streamBase)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Returns", selection: $s.streamType) {
                    ForEach(StreamType.allCases) { Text($0.label).tag($0) }
                }
                TextField("Catalog URL (optional)", text: $s.catalogBase)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Access token (optional)", text: $s.serverToken)
            } header: {
                Text("Your media server")
            } footer: {
                Text("Plays {url}/movie/{tmdbId} and {url}/tv/{tmdbId}/{season}/{episode}. The catalog defaults to the Stream URL.")
            }

            SyncSettingsSection()

            Section("Catalog (TMDB)") {
                SecureField("TMDB read access token", text: $s.tmdbToken)
                TextField("Language", text: $s.language).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Region (e.g. US)", text: $s.region).textInputAutocapitalization(.characters).autocorrectionDisabled()
            }

            Section {
                SecureField("SubDL API key", text: $s.subdlKey)
                TextField("Languages (e.g. EN,SV)", text: $s.subLangs).textInputAutocapitalization(.characters).autocorrectionDisabled()
            } header: {
                Text("Subtitles (SubDL)")
            } footer: {
                Text("Free key at subdl.com/panel/api. In the player, tap the subtitles button to search.")
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Test connections")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(Theme.text2) }
            }

            Section {
                Button("Clear watch history", role: .destructive) { confirmClear = true }
            } footer: {
                Text("Removes Continue Watching and episode progress. My List and Watched are kept.")
            }

            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .confirmationDialog("Clear watch history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { library.clearHistory() }
        }
        .onDisappear {
            Task {
                await ResponseCache.shared.clear()
                await catalog.refresh(settings, force: true)
                await catalog.loadGenres(settings.tmdb)
            }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        await ResponseCache.shared.clear()
        var lines: [String] = []
        do {
            _ = try await settings.tmdb.genres(.movie)
            lines.append("TMDB: connected")
        } catch {
            lines.append("TMDB: \(error.localizedDescription)")
        }
        if settings.server.isConfigured || !settings.catalogBase.isEmpty {
            if let items = await settings.server.catalog() {
                lines.append("Server: connected (\(items.count) titles)")
            } else {
                lines.append("Server: no /catalog (all titles playable)")
            }
            await catalog.refresh(settings, force: true)
        } else {
            lines.append("Server: not configured")
        }
        status = lines.joined(separator: "\n")
    }
}
