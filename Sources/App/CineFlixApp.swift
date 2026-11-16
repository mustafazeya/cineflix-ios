import SwiftUI
import AVFoundation

@main
struct CineFlixApp: App {
    @State private var settings: AppSettings
    @State private var library: Library
    @State private var catalog = CatalogState()
    @State private var kidsVisibility = KidsVisibility()
    @State private var presenter = PlayerPresenter()
    @State private var sync: SyncService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = AppSettings()
        let library = Library()
        _settings = State(initialValue: settings)
        _library = State(initialValue: library)
        _sync = State(initialValue: SyncService(library: library, settings: settings))
        URLCache.shared = URLCache(memoryCapacity: 96 << 20, diskCapacity: 512 << 20)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        CastManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(library)
                .environment(catalog)
                .environment(presenter)
                .environment(sync)
                .environment(kidsVisibility)
                .preferredColorScheme(.dark)
                .tint(.white)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { sync.activate() } else { sync.deactivate() }
                }
        }
    }
}

private struct ContinueCheck: Hashable { let refs: [MediaRef]; let policy: KidsPolicy? }
private struct AppSession: Hashable { let profile: String?; let policy: KidsPolicy? }

enum AppTab: Hashable { case home, browse, mine, search }

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(CatalogState.self) private var catalog
    @Environment(PlayerPresenter.self) private var presenter
    @Environment(SyncService.self) private var sync
    @Environment(Library.self) private var library
    @Environment(KidsVisibility.self) private var visibility
    @State private var tab: AppTab = .home
    @State private var splash = true
    @State private var showSettings = false
    @State private var searchQuery = ""

    var body: some View {
        @Bindable var presenter = presenter
        ZStack {
            TabView(selection: $tab) {
                Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                    NavigationStack { HomeView().withRoutes() }
                }
                Tab("Browse", systemImage: "square.grid.2x2.fill", value: AppTab.browse) {
                    NavigationStack { BrowseView().withRoutes() }
                }
                Tab("My Stuff", systemImage: "person.crop.circle", value: AppTab.mine) {
                    NavigationStack { MyStuffView().withRoutes() }
                }
                Tab(value: AppTab.search, role: .search) {
                    SearchView(query: $searchQuery)
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .background(Theme.bg)
            // A new profile, or new restrictions, start every tab over: rows, search, open title pages. A kids profile never sees
            // what the previous profile had open.
            .id(AppSession(profile: sync.activeProfileID, policy: settings.kidsPolicy))

            if splash {
                SplashView().transition(.opacity).zIndex(1)
            }
        }
        .task {
            async let g: Void = catalog.loadGenres(settings.tmdb)
            async let c: Void = catalog.refresh(settings)
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.45)) { splash = false }
            _ = await (g, c)
            if !settings.hasTMDB { showSettings = true }
        }
        .task(id: ContinueCheck(refs: library.continueWatching.map(\.ref), policy: settings.kidsPolicy)) {
            await visibility.refresh(library.continueWatching.map(\.ref), policy: settings.kidsPolicy, tmdb: settings.tmdb)
        }
        .fullScreenCover(isPresented: Binding(get: { sync.needsProfile || sync.showPicker }, set: { if !$0 { sync.showPicker = false } })) {
            ProfilePickerView(dismissable: !sync.needsProfile)
        }
        .pinGate()
        .fullScreenCover(item: $presenter.current) { request in
            PlayerScreen(request: request)
        }
        .fullScreenCover(item: $presenter.trailerKey) { key in
            TrailerScreen(videoKey: key.id)
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .sheet(isPresented: $presenter.needsSetup) {
            NavigationStack { SettingsView(reason: "Set your Stream URL to play titles from your server.") }
        }
    }
}

struct SplashView: View {
    @State private var shown = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image("Wordmark")
                .resizable()
                .scaledToFit()
                .frame(width: 210)
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { shown = true } }
    }
}
