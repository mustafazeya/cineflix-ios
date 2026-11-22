import SwiftUI
import AVKit
import WebKit

/// Resolves the stream for a request, then shows the native player (video) or the web player (page).
/// Saves progress, marks finished titles watched and autoplays the next episode.
struct PlayerScreen: View {
    @State var request: PlaybackRequest

    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var subtitles = SubtitleController()
    @State private var showSubtitles = false
    @State private var cast = CastManager.shared
    /// True while the video plays on the TV and this screen is its remote.
    @State private var casting = false
    /// The user chose to watch on the phone although a TV is connected.
    @State private var localOnly = false
    @State private var track = PositionTrack()

    /// The playing position, kept outside @State so its quarter-second updates do not redraw the screen.
    final class PositionTrack {
        var position = 0.0; var duration = 0.0; var clockWeight = 0.0; var clockAt = Date.distantPast
        var paused = false
        var touchedAt = Date()
        /// The hidden page last did something (a request, a video loading), and how many addresses are being looked at.
        var pageActiveAt = Date()
        var probing = 0
        /// The system player's own controls were seen: our buttons then follow them exactly instead of a timer.
        var followsSystem = false
    }

    /// Our buttons over the video. They fade out a few seconds after the last touch (like the system player's own controls underneath)
    /// and come back on a touch, or while the next-episode card is up, the video is paused, or something needs attention.
    @State private var chromeVisible = true
    private static let chromeSeconds = 4.0

    /// Stream addresses the web page loaded its media from, so the page's video can be played natively (AirPlay, Chromecast).
    @State private var streams = StreamPicker()
    @State private var pageControl = WebPageControl()
    /// Set while the native player shows a stream found on a web page: the page to go back to, and how the page loaded the stream.
    @State private var pageURL: URL?
    @State private var nativeStream: NativeStream?
    /// The stream plays through this phone's own web server, which adds the page's Referer, cookies and User-Agent to every request.
    @State private var nativeViaPhone = false
    /// The stream failed through the phone, so it was tried straight from the server (with the page's headers) before giving up.
    @State private var triedDirect = false
    @State private var playerEpoch = 0
    /// Why the app's own player was given up on, shown for a few seconds over the page player it fell back to.
    @State private var fallbackNote = ""
    /// What the hidden page loaded, in a few words per request.
    @State private var pageTrace = ""
    @State private var nativeError = ""
    /// A server page is opened out of sight first: its stream is found and played in the app's own player. The page itself only comes forward
    /// when no stream shows up in time (it may need a tap on its play button) or when the app's player could not play the stream.
    @State private var pageRevealed = false
    /// The app's own player was tried and failed (or the page was asked for): stop switching to it by itself.
    @State private var preferPage = false
    private static var pageWait: Double { UserDefaults.standard.object(forKey: "cf.pageReveal") == nil ? 12 : UserDefaults.standard.double(forKey: "cf.pageReveal") }
    @State private var nativeFailed = false
    private static let showClock = UserDefaults.standard.bool(forKey: "cf.testClock")
    /// Diagnostics (why the page player was used, what the page loaded) are only drawn on request: `-cf.showPageNote YES`.
    private static let showNote = UserDefaults.standard.bool(forKey: "cf.showPageNote")

    struct Ending: Equatable { var deadline: Date?; var finished = false }
    @State private var upNext: UpNext?
    @State private var ending: Ending?
    /// The user chose to keep watching the credits; the card stays away until they seek back or the video ends.
    @State private var creditsChosen = false

    /// `local` is the file as a plain web address served by this phone, which is what lets AirPlay play a MEGA file; without it the player decrypts in-app.
    enum Phase { case resolving, video(URL), mega(MegaDownload, local: URL?), page(URL), failed(String) }
    @State private var phase: Phase = .resolving

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if casting {
                CastRemoteView(request: request, cast: cast, onLocal: watchOnPhone)
            } else {
            switch phase {
            case .resolving:
                VStack(spacing: 14) {
                    ProgressView().tint(.white).controlSize(.large)
                    Text(request.title).font(.headline)
                    if let s = request.subtitle { Text(s).font(.subheadline).foregroundStyle(Theme.dim) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .video(let url):
                VideoPlayerView(subtitles: subtitles, url: url, access: !nativeViaPhone && nativeStream?.url == url ? nativeStream : nil, resume: request.resume,
                                onProgress: { [id = request.id] p, d in progressed(p, d, for: id) }, onClock: { subtitles.setClock(position: $0, paused: $1); track.position = $0; track.paused = $1 },
                                onEnd: { [id = request.id] in ended(for: id) },
                                onTouch: touched, onControls: systemControls,
                                onFail: pageURL == nil ? nil : { [id = request.id] in if id == request.id { nativeFailed(url) } },
                                onFailDetail: { nativeError = $0 })
                    .ignoresSafeArea()
                    .id("\(request.id)-\(playerEpoch)")
                if nativeFailed, pageURL != nil { nativeFailure }
            case .mega(let dl, let local):
                VideoPlayerView(subtitles: subtitles, url: local ?? dl.url, mega: local == nil ? dl : nil, resume: request.resume, onProgress: { [id = request.id] p, d in progressed(p, d, for: id) },
                                onClock: { p, paused in track.position = p; track.paused = paused }, onEnd: { [id = request.id] in ended(for: id) }, onTouch: touched, onControls: systemControls,
                                onFail: local == nil ? nil : { phase = .mega(dl, local: nil) })
                    .ignoresSafeArea()
                    .id(request.id)
            case .page(let url):
                ZStack {
                    WebPlayerView(url: url, cues: subtitles.cues, offset: subtitles.offset, resume: request.resume, control: pageControl,
                                  onProgress: { [id = request.id] p, d in progressed(p, d, for: id) },
                                  onClock: { pageClock(position: $0, paused: $1, weight: $2) }, onEnd: { [id = request.id] in ended(for: id) }, onClose: { dismiss() },
                                  onStream: { [id = request.id] found in
                                      guard id == request.id else { return }
                                      if found.kind == .candidate { probe(found) } else { streams.offer(found) }
                                  },
                                  onTrace: { [id = request.id] t, active in
                                      guard id == request.id else { return }
                                      pageTrace = t
                                      if active { track.pageActiveAt = Date() }
                                  }, onTouch: touched)
                        .ignoresSafeArea()
                        .id(request.id)
                    if !pageRevealed { preparing }
                }
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Theme.text2)
                    Text(message).multilineTextAlignment(.center).foregroundStyle(Theme.text2)
                    Button("Close") { dismiss() }.buttonStyle(.glass)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }

            if !isNativeVideo && !casting { SubtitleOverlay(controller: subtitles) }

            if Self.showNote, !fallbackNote.isEmpty, case .page = phase {
                VStack {
                    Spacer()
                    Text((fallbackNote.hasPrefix("Page loaded") || fallbackNote.hasPrefix("The page loaded") ? "Playing in the page player: no stream found.\n" : "Played in the page player instead.\n") + fallbackNote)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.leading)
                        .padding(10).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).padding(.bottom, 30).textSelection(.enabled)
                        .accessibilityIdentifier("fallback-note")
                }
                .allowsHitTesting(false)
            }

            if Self.showClock {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(String(Int(track.position))).font(.system(size: 6)).foregroundStyle(.white.opacity(0.02)).accessibilityIdentifier("player-clock")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
            }

            if let up = upNext, let ending {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        NextEpisodeCard(next: up, deadline: ending.deadline, finished: ending.finished, onPlay: advance,
                                        onDismiss: { ending.finished ? dismiss() : keepWatching() })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 84)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack {
                // The system player shows its own close button and AirPlay button in its controls; ours would sit on top of them.
                if !isNativeVideo || casting {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close")
                }
                Spacer()
                if (isNativeVideo || casting), cast.hasDevices || cast.hasSession {
                    PlayerControl { CastButton() }.accessibilityLabel("Cast")
                }
                if upNext != nil, ending == nil, !isFailed {
                    Button(action: advance) {
                        Image(systemName: "forward.end.fill").font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 38)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Next episode")
                }
                if settings.hasSubDL, !isFailed, !request.isCustom {
                    Button { showSubtitles = true } label: {
                        Image(systemName: subtitles.isOn ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Subtitles")
                }
            }
            .padding(.leading, 16)
            // The system player keeps its speaker button at the top right and its own buttons at the top left; ours sit between them.
            .padding(.trailing, isNativeVideo && !casting ? 72 : 16)
            .padding(.top, isNativeVideo && !casting ? -3 : 8)
            .opacity(chromeShown ? 1 : 0)
            .allowsHitTesting(chromeShown)
            .simultaneousGesture(TapGesture().onEnded { touched() })
            .animation(.easeOut(duration: 0.25), value: chromeShown)
        }
        .sheet(isPresented: $showSubtitles) { SubtitleSheet(request: request, controller: subtitles) }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task(id: request.id) { await resolve() }
        .task(id: request.id) { await watchEnding() }
        .task { await watchChrome() }
        .task(id: request.id) { await revealPageSoon() }
        .task(id: streams.best) { await playFoundStream() }
        .onChange(of: pageRevealed) { _, shown in pageControl.mute?(!shown) }
        .animation(.easeOut(duration: 0.25), value: ending)
        .onChange(of: cast.hasSession) { _, connected in
            if connected { if !casting { startCasting() } } else if casting { backToPhone() }
        }
        .onChange(of: cast.isCasting) { _, on in
            // The TV could not load or play the video: carry on here, from where it got to.
            if !on, casting { localOnly = true; backToPhone() }
        }
        .onChange(of: Int(cast.position / 5)) { _, _ in
            if casting, cast.duration > 0 { save(position: cast.position, duration: cast.duration) }
        }
        .onChange(of: subtitles.name) { _, _ in
            if casting { Task { await cast.updateCaptions(captionText) } }
        }
        .onDisappear {
            CastProxy.shared.stop()
            guard casting else { return }
            if cast.duration > 0 { save(position: cast.position, duration: cast.duration) }
            cast.stopPlayback()
        }
    }

    /// Shown over the native player when a stream taken from a web page would not play.
    private var nativeFailure: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Theme.text2)
            Text("This stream doesn't play outside the page.").multilineTextAlignment(.center).foregroundStyle(Theme.text2)
            if Self.showNote, !nativeError.isEmpty { Text(nativeError).font(.caption).multilineTextAlignment(.center).foregroundStyle(Theme.dim).textSelection(.enabled) }
            if Self.showNote, !CastProxy.shared.trace.isEmpty { Text(CastProxy.shared.trace).font(.system(size: 10, design: .monospaced)).multilineTextAlignment(.leading).foregroundStyle(Theme.dim).textSelection(.enabled) }
            HStack(spacing: 12) {
                Button("Open page player") { if let pageURL { backToPage(pageURL) } }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("back-to-page")
                Button("Close") { dismiss() }.buttonStyle(.glass)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    /// The page's own clock follows the largest video in any frame, which is also the one to continue from.
    private func pageClock(position: Double, paused: Bool, weight: Double) {
        subtitles.setClock(position: position, paused: paused, weight: weight)
        if weight >= track.clockWeight || Date().timeIntervalSince(track.clockAt) > 1.5 {
            track.position = position
            track.clockWeight = weight
            track.clockAt = Date()
            track.paused = paused
        }
    }

    /// Shown over the page while its stream is being found.
    private var preparing: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.white).controlSize(.large)
            Text(request.title).font(.headline)
            if let s = request.subtitle { Text(s).font(.subheadline).foregroundStyle(Theme.dim) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    private func revealPageSoon() async {
        // A page that is still busy (requests going out, its video loading) gets more time: it is the app's own player the viewer wants, and
        // showing the page's loading screen only to switch away from it a moment later is worse than waiting. A page that has gone quiet is
        // shown after the normal wait, and the longest any page is given is 45 seconds.
        let started = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard case .page = phase, !pageRevealed else { return }
            if streams.best != nil || track.probing > 0 { continue }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= Self.pageWait && (Date().timeIntervalSince(track.pageActiveAt) >= 6 || elapsed >= 45) { break }
        }
        guard !Task.isCancelled, case .page = phase else { return }
        pageRevealed = true
        // No stream was found, so the page it is: say what it loaded, because that is what shows why nothing playable turned up.
        if streams.best == nil {
            fallbackNote = (streams.rejectedNotes + [pageTrace.isEmpty ? "The page loaded no media." : "Page loaded:\n" + pageTrace]).joined(separator: "\n")
            try? await Task.sleep(for: .seconds(20))
            fallbackNote = ""
        }
    }

    /// The page's stream is known: after a moment (a master playlist may follow a quality playlist) it plays in the app's own player.
    private func playFoundStream() async {
        guard let found = streams.best else { return }
        try? await Task.sleep(for: .milliseconds(1200))
        guard !Task.isCancelled, case .page = phase, !preferPage, let best = streams.best, best.url == found.url else { return }
        // A file of a few hundred bytes is not a video: it is the first piece of a stream the page puts together itself, and the page's own
        // player is the only thing that can play that. Leave it to the page.
        if best.kind == .file {
            let stream = NativeStream(url: best.url, referer: best.referer, userAgent: best.userAgent, cookies: await pageControl.cookies(for: best.url))
            if let size = await Self.fileSize(of: stream), size < Self.minimumVideoBytes {
                streams.reject(best.url, because: "Ignored \(best.url.lastPathComponent): a file of only \(size) bytes is not a video.")
                return
            }
        }
        playNatively(best)
    }

    private static let minimumVideoBytes: Int64 = 200_000

    /// An address whose kind is not known by its name: read its first bytes (with what the page sent) and see what it is.
    private func probe(_ found: DetectedStream) {
        guard streams.shouldProbe(found.url) else { return }
        let id = request.id
        track.probing += 1
        Task {
            let stream = NativeStream(url: found.url, referer: found.referer, userAgent: found.userAgent, cookies: await pageControl.cookies(for: found.url))
            let kind = await Self.classify(found, stream)
            track.probing -= 1
            guard id == request.id, case .page = phase else { return }
            if let kind { streams.offer(kind) }
        }
    }

    /// nil when the address is not a playlist or a video file the iPhone can play.
    private static func classify(_ found: DetectedStream, _ stream: NativeStream) async -> DetectedStream? {
        var request = URLRequest(url: found.url, timeoutInterval: 12)
        for (name, value) in stream.proxyHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request), let http = response as? HTTPURLResponse, http.statusCode < 400 else { return nil }
        var head = [UInt8]()
        do { for try await byte in bytes { head.append(byte); if head.count >= 4096 { break } } } catch {}
        func make(_ kind: DetectedStream.Kind, _ variants: Set<URL> = []) -> DetectedStream {
            DetectedStream(url: found.url, kind: kind, variants: variants, referer: found.referer, userAgent: found.userAgent)
        }
        let text = String(decoding: head, as: UTF8.self)
        if text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\n\r\t ")).hasPrefix("#EXTM3U") {
            guard text.contains("#EXT-X-STREAM-INF") else { return make(text.contains("#EXTINF") ? .media : .hls) }
            var variants = Set<URL>()
            var next = false
            for line in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if line.hasPrefix("#EXT-X-STREAM-INF") { next = true; continue }
                if next, !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line, relativeTo: found.url)?.absoluteURL { variants.insert(url); next = false }
            }
            return make(.master, variants)
        }
        if head.count >= 8 {
            let tag = String(decoding: head[4..<8], as: UTF8.self)
            if ["ftyp", "moov", "mdat", "styp", "free", "wide"].contains(tag) { return make(.file) }
        }
        if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return make(.file) }
        return nil
    }

    /// The size of the file behind a stream address, read from the first byte's answer. nil when the server does not say.
    private static func fileSize(of stream: NativeStream) async -> Int64? {
        var request = URLRequest(url: stream.url, timeoutInterval: 10)
        for (name, value) in stream.proxyHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.bytes(for: request), let http = response as? HTTPURLResponse else { return nil }
        if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last.flatMap({ Int64($0) }) { return total }
        if http.statusCode == 200, let length = http.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }) { return length }
        return nil
    }

    private func touched() {
        track.touchedAt = Date()
        if !track.followsSystem, !chromeVisible { chromeVisible = true }
    }

    /// The system controls came or went; our buttons do the same, so the two never disagree.
    private func systemControls(visible: Bool) {
        track.followsSystem = true
        if chromeVisible != visible { chromeVisible = visible }
    }

    /// Only a playing video hides our buttons. Anything that needs the viewer (the next-episode card, a pause, an error, a TV remote) shows them.
    private var preparingPage: Bool { if case .page = phase { !pageRevealed } else { false } }

    private var chromeShown: Bool {
        if chromeVisible || casting || ending != nil || preparingPage { return true }
        switch phase {
        case .video, .mega, .page: return false
        default: return true
        }
    }

    private func watchChrome() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(400))
            if track.followsSystem, isNativeVideo, !casting { continue }
            if casting || ending != nil || track.paused || showSubtitles || preparingPage { track.touchedAt = Date(); if !chromeVisible { chromeVisible = true }; continue }
            if chromeVisible, Date().timeIntervalSince(track.touchedAt) > Self.chromeSeconds { chromeVisible = false }
        }
    }

    /// Replaces the page with the native player on the stream the page was loading, at the page video's position. AirPlay and Chromecast
    /// can then show the picture. Nothing else changes: the page stays the default, and the way back is one tap.
    private func playNatively(_ found: DetectedStream) {
        guard case .page(let page) = phase else { return }
        touched()
        Task {
            let stream = NativeStream(url: found.url, referer: found.referer, userAgent: found.userAgent, cookies: await pageControl.cookies(for: found.url))
            guard case .page = phase else { return }
            nativeStream = stream
            nativeFailed = false
            nativeError = ""
            triedDirect = false
            pageURL = page
            request.resume = track.position
            // The phone fetches the stream itself and adds what the page sent on every request, so servers that check the Referer or cookies
            // still answer, for its own player and for an AirPlay receiver (which fetches from the phone, not from the server).
            let viaPhone = await CastProxy.shared.publish(.url(found.url, headers: stream.proxyHeaders), playlist: found.kind != .file)
            nativeViaPhone = viaPhone != nil
            phase = .video(viaPhone ?? found.url)
            startCasting()
        }
    }

    /// The app's player could not play the stream. Through the phone failed: try it straight from the server once, then give up.
    private func nativeFailed(_ url: URL) {
        if nativeViaPhone, !triedDirect, let original = nativeStream?.url {
            triedDirect = true
            nativeViaPhone = false
            playerEpoch += 1
            phase = .video(original)
            return
        }
        // Both ways failed. The page's own player can usually still play it (it decodes the video itself), so go there instead of stopping.
        if let page = pageURL, !preferPage {
            let trace = CastProxy.shared.trace
            fallbackNote = [nativeError, trace, pageTrace.isEmpty ? "" : "Page loaded:\n" + pageTrace].filter { !$0.isEmpty }.joined(separator: "\n")
            backToPage(page)
            Task { try? await Task.sleep(for: .seconds(12)); fallbackNote = "" }
            return
        }
        nativeFailed = true
    }

    private func backToPage(_ page: URL) {
        touched()
        pageRevealed = true
        preferPage = true
        request.resume = track.position
        nativeFailed = false
        nativeStream = nil
        nativeViaPhone = false
        pageURL = nil
        phase = .page(page)
    }

    private var captionText: String? { subtitles.isOn ? CastProxy.webVTT(cues: subtitles.cues, offset: subtitles.offset) : nil }

    /// With a TV connected, what plays goes to the TV and this screen becomes its remote.
    private func startCasting() {
        guard !localOnly, cast.hasSession else { return }
        let source: CastProxy.Source
        switch phase {
        case .video(let url): source = .url(nativeStream?.url ?? url, headers: nativeStream?.proxyHeaders ?? [:])
        case .mega(let download, _): source = .mega(download)
        default: return
        }
        let resume = track.position > 5 ? track.position : request.resume
        casting = true
        let id = request.id
        cast.onFinished = { duration in
            casting = false
            track.position = 0
            if duration > 0 { save(position: duration, duration: duration) }
            ended(for: id)
        }
        let media = CastManager.Media(source: source, title: request.title, subtitle: request.subtitle,
                                      artwork: TMDB.image(request.backdropPath ?? request.posterPath, "w780"))
        let captions = captionText
        Task { await cast.load(media, resume: resume, captions: captions) }
    }

    /// Back to the phone's own player at the TV's position.
    private func backToPhone() {
        request.resume = cast.position
        track.position = cast.position
        casting = false
    }

    private func watchOnPhone() {
        localOnly = true
        let at = cast.position
        cast.stopPlayback()
        request.resume = at
        track.position = at
        casting = false
    }

    private var airPlayable: Bool {
        switch phase {
        case .video: true
        case .mega(_, let local): local != nil
        default: false
        }
    }

    private var isNativeVideo: Bool { switch phase { case .video, .mega: true; default: false } }
    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    private func loadSavedSubtitle() {
        subtitles.clear()
        subtitles.resetClock()
        guard settings.hasSubDL, !request.isCustom,
              let s = SubtitleStore.saved(SubtitleStore.key(request.ref, season: request.season, episode: request.episode)) else { return }
        let cues = SubtitleParser.parse(s.text)
        if !cues.isEmpty { subtitles.load(text: s.text, cues: cues, name: s.name, lang: s.lang, offset: s.offset) }
    }

    private func resolve() async {
        touched()
        pageRevealed = false
        preferPage = false
        pageTrace = ""
        track.pageActiveAt = Date()
        track.probing = 0
        track.followsSystem = false
        streams.reset()
        upNext = nil
        ending = nil
        creditsChosen = false
        track.duration = 0
        track.clockWeight = 0
        casting = false
        streams.reset()
        pageURL = nil
        nativeStream = nil
        nativeFailed = false
        // A saved link or MEGA file starts where it was left, here or on another device. This also covers the file autoplay moves on to.
        if request.resumeKey != nil, request.resume == 0 { request.resume = library.resumePosition(request.resumeKey) }
        track.position = request.resume
        phase = .resolving
        loadSavedSubtitle()
        Task { await prefetchNext() }
        do {
            if let m = request.mega {
                let download = try await megaDownload(m)
                phase = .mega(download, local: await CastProxy.shared.publish(.mega(download)))
                startCasting()
                return
            }
            let found: Playback
            if let link = request.link { found = try await settings.server.resolveLink(link) }
            else { found = try await settings.server.resolve(request.ref, season: request.season, episode: request.episode) }
            switch found {
            case .video(let url): phase = .video(url)
            case .page(let url): phase = .page(url)
            }
            startCasting()
            // A page without progress reporting still counts as "started" for Continue Watching.
            if !request.isCustom, library.progress(for: request.ref) == nil || request.ref.type == .tv {
                save(position: request.resume, duration: 0, initial: true)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func megaDownload(_ m: MegaPlay) async throws -> MegaDownload {
        guard let link = MegaLink.parse(m.linkText) else { throw MegaError.message("This MEGA link is not valid.") }
        let folder = try await MegaStore.shared.folder(for: link)
        guard let node = folder.node(m.node) else { throw MegaError.message("That file is no longer in the MEGA link.") }
        guard MegaFormat.playsOnPhone(node.name) else { throw MegaError.unsupported(MegaFormat.ext(node.name)) }
        return try await MegaAPI.download(link, node)
    }

    private func save(position: Double, duration: Double) { save(position: position, duration: duration, initial: false) }

    private func save(position: Double, duration: Double, initial: Bool) {
        if let key = request.resumeKey {
            library.recordResume(key: key, position: position, duration: duration, title: request.title)
            return
        }
        guard !request.isCustom else { return }
        var duration = duration
        if initial, let p = library.progress(for: request.ref), p.season == request.season, p.episode == request.episode {
            duration = p.duration
        }
        library.record(WatchProgress(ref: request.ref, season: request.season, episode: request.episode,
                                     position: position, duration: duration, title: request.title, subtitle: request.subtitle,
                                     backdropPath: request.backdropPath, posterPath: request.posterPath, stillPath: request.stillPath,
                                     updatedAt: Date(), finished: false),
                       item: request.item)
    }

    /// Progress from a player that was just replaced (it reports once more while closing) belongs to the old video and is dropped.
    private func progressed(_ position: Double, _ duration: Double, for id: UUID) {
        guard id == request.id else { return }
        track.duration = duration
        save(position: position, duration: duration)
    }

    /// The video is over (or the TV finished it): continue with the next one, or show its card, or leave.
    private func ended(for id: UUID) {
        // A video that finishes just as its successor was started must not start a second one.
        guard id == request.id else { return }
        if request.resumeKey != nil, track.duration > 0 { save(position: track.duration, duration: track.duration) }
        Task {
            if upNext == nil { await prefetchNext() }
            guard upNext != nil else { dismiss(); return }
            if settings.autoplayNext && !creditsChosen { advance() } else { ending = Ending(deadline: nil, finished: true) }
        }
    }

    private func keepWatching() {
        creditsChosen = true
        ending = nil
    }

    /// Starts the next video now. The one that is leaving counts as finished.
    private func advance() {
        guard let up = upNext else { return }
        let length = casting ? cast.duration : track.duration
        if length > 0 { save(position: length, duration: length) }
        ending = nil
        upNext = nil
        request = up.request
    }

    /// Looks up what follows the current video, so the card is ready when it is needed.
    private func prefetchNext() async {
        guard upNext == nil else { return }
        let current = request.id
        var found: UpNext?
        if let m = request.mega {
            found = await megaNext(after: m)
        } else if request.ref.type == .tv, !request.isCustom, let s = request.season, let e = request.episode,
                  let next = await settings.tmdb.nextEpisode(showID: request.ref.id, season: s, episode: e) {
            let r = request
            found = UpNext(label: "S\(next.season):E\(next.episode.episodeNumber)", name: next.episode.name,
                           still: TMDB.image(next.episode.stillPath ?? r.backdropPath, "w300"),
                           request: PlaybackRequest(ref: r.ref, season: next.season, episode: next.episode.episodeNumber, title: r.title,
                                                    subtitle: next.episode.name, backdropPath: r.backdropPath, posterPath: r.posterPath,
                                                    stillPath: next.episode.stillPath, resume: 0, item: r.item))
        }
        if request.id == current { upNext = found }
    }

    /// Shows the card in the last 30 seconds, counts down, and starts the next video when it reaches zero.
    private func watchEnding() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard upNext != nil, ending?.finished != true else { continue }
            let duration = casting ? cast.duration : track.duration
            let left = duration - (casting ? cast.position : track.position)
            // UI tests shorten both through launch arguments, because their test video is only seconds long.
            let defaults = UserDefaults.standard
            let lead = defaults.object(forKey: "cf.nextLead") == nil ? 30 : defaults.double(forKey: "cf.nextLead")
            guard duration > (defaults.object(forKey: "cf.nextMinLength") == nil ? 300 : defaults.double(forKey: "cf.nextMinLength")) else { continue }
            if left <= lead {
                if ending == nil, !creditsChosen {
                    ending = Ending(deadline: settings.autoplayNext ? Date().addingTimeInterval(min(10, max(left, 3))) : nil)
                }
                if let deadline = ending?.deadline, Date() >= deadline { advance() }
            } else if ending != nil || creditsChosen {
                // Sought back out of the credits: the card comes again when they are reached.
                ending = nil
                creditsChosen = false
            }
        }
    }

    /// After a file in a MEGA folder, the next playable video in the same folder.
    private func megaNext(after m: MegaPlay) async -> UpNext? {
        guard let link = MegaLink.parse(m.linkText), let folder = try? await MegaStore.shared.folder(for: link),
              let node = folder.node(m.node) else { return nil }
        let siblings = folder.children(of: node.parent).filter { !$0.isDir && MegaFormat.playsOnPhone($0.name) }
        guard let at = siblings.firstIndex(where: { $0.id == node.id }), at + 1 < siblings.count else { return nil }
        let next = siblings[at + 1]
        let title = (next.name as NSString).deletingPathExtension
        return UpNext(label: "Next video", name: title, still: nil,
                      request: PlaybackRequest(ref: request.ref, title: title, subtitle: request.subtitle, mega: MegaPlay(linkText: m.linkText, node: next.id, videoID: m.videoID),
                                               resumeKey: m.videoID.map { ResumeKey.mega(videoID: $0, node: next.id) }))
    }
}

/// Hears every touch on a view without taking part in it, so the video's own controls keep working. The player uses it to know when to bring its buttons back.
final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let onTouch: () -> Void

    init(_ onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

// MARK: - Native player

struct VideoPlayerView: UIViewControllerRepresentable {
    let subtitles: SubtitleController
    let url: URL
    /// How a web page loaded this stream (Referer, User-Agent, cookies), when the stream was found on one.
    var access: NativeStream?
    var mega: MegaDownload?
    let resume: Double
    let onProgress: (Double, Double) -> Void
    let onClock: (Double, Bool) -> Void
    let onEnd: () -> Void
    var onTouch: (() -> Void)?
    /// Whether the system player's own controls are on screen. Called when that changes.
    var onControls: ((Bool) -> Void)?
    var onFail: (() -> Void)?
    /// What went wrong, in words (HTTP status of the failing request, or the player's own message), shown so a refused stream can be understood.
    var onFailDetail: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.player = context.coordinator.start()
        if let onTouch { vc.view.addGestureRecognizer(TouchWatcher(onTouch)) }
        if let onControls { context.coordinator.watchControls(of: vc, onControls) }
        // The video's own overlay layer stays on screen in the player's full screen mode, unlike our SwiftUI view.
        let host = UIHostingController(rootView: SubtitleOverlay(controller: subtitles))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        if let overlay = vc.contentOverlayView {
            overlay.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: overlay.topAnchor), host.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor)
            ])
            context.coordinator.overlayHost = host
        }
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.stop()
        vc.player = nil
    }

    final class Coordinator {
        let parent: VideoPlayerView
        var overlayHost: UIHostingController<SubtitleOverlay>?
        private var megaLoader: MegaStreamLoader?
        private var player: AVPlayer?
        private var timeObserver: Any?
        private var clockObserver: Any?
        private var statusObservation: NSKeyValueObservation?
        private var endObserver: NSObjectProtocol?
        private var didSeek = false

        init(_ parent: VideoPlayerView) { self.parent = parent }

        func start() -> AVPlayer {
            let item: AVPlayerItem
            if let dl = parent.mega {
                let loader = MegaStreamLoader(dl)
                megaLoader = loader
                item = AVPlayerItem(asset: loader.makeAsset())
            } else {
                item = AVPlayerItem(asset: parent.access.map { AVURLAsset(url: parent.url, options: $0.assetOptions) } ?? AVURLAsset(url: parent.url))
            }
            let player = AVPlayer(playerItem: item)
            self.player = player

            // Nothing playing 25 seconds in, and no error either: say so instead of leaving a black screen.
            watchdog = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let player = self.player, player.timeControlStatus != .playing, !self.stalledReported else { return }
                    self.stalledReported = true
                    let reason = player.reasonForWaitingToPlay?.rawValue ?? "no reason given"
                    self.parent.onFailDetail?("Nothing started playing after 25 seconds (\(reason)).")
                    self.parent.onFail?()
                }
            }

            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    if item.status == .failed {
                        let event = item.errorLog()?.events.last { $0.errorStatusCode != 0 }
                        var detail = item.error?.localizedDescription ?? "Playback failed."
                        if let error = item.error as NSError? {
                            // The code is what tells a refused request from an unreadable stream.
                            let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " > \($0.domain) \($0.code)" } ?? ""
                            detail += " (\(error.domain) \(error.code)\(underlying))"
                        }
                        if let event {
                            let uri = event.uri.flatMap(URL.init(string:))
                            detail = "HTTP \(event.errorStatusCode) from \(uri?.host ?? "the server")" + (uri.map { " " + $0.lastPathComponent } ?? "")
                        } else if let problem = CastProxy.shared.lastProblem {
                            detail = problem + " - " + detail
                        }
                        self?.parent.onFailDetail?(detail)
                        self?.parent.onFail?()
                        return
                    }
                    guard let self, item.status == .readyToPlay, !self.didSeek else { return }
                    // A file whose video the iPhone cannot decode still "plays": the sound runs under a black screen, with no error at all.
                    if let problem = await Self.videoProblem(of: item.asset) {
                        self.parent.onFailDetail?(problem)
                        self.parent.onFail?()
                        return
                    }
                    self.didSeek = true
                    let duration = item.duration.seconds
                    if self.parent.resume > 5, duration.isFinite, self.parent.resume < duration - 10 {
                        await player.seek(to: CMTime(seconds: self.parent.resume, preferredTimescale: 600))
                    }
                    player.play()
                }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, let item = self.player?.currentItem else { return }
                    let duration = item.duration.seconds
                    if duration.isFinite, duration > 0 { self.parent.onProgress(time.seconds, duration) }
                }
            }
            clockObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, let player = self.player, time.seconds.isFinite else { return }
                    self.parent.onClock(time.seconds, player.timeControlStatus != .playing)
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let d = item.duration.seconds
                    if d.isFinite { self.parent.onProgress(d, d) }
                    self.parent.onEnd()
                }
            }
            player.play()
            return player
        }

        private var controlsTimer: Timer?
        private var watchdog: Timer?
        private var stalledReported = false
        private var controlsShown: Bool?

        /// Reads whether the system controls are showing from the dimming layer they fade in over the video (alpha 0 hidden, 1 shown), or
        /// from their container being hidden. These are the player's own views, found by name: if a later iOS renames them nothing is
        /// reported and the player screen keeps hiding its buttons on a timer instead.
        func watchControls(of vc: AVPlayerViewController, _ report: @escaping (Bool) -> Void) {
            controlsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak vc] _ in
                guard let self, let root = vc?.view, let visible = Self.controlsVisible(in: root), visible != self.controlsShown else { return }
                self.controlsShown = visible
                report(visible)
            }
        }

        private static func controlsVisible(in root: UIView) -> Bool? {
            var dimming: UIView?
            var container: UIView?
            func walk(_ view: UIView) {
                let name = String(describing: type(of: view))
                if dimming == nil, name.hasSuffix("BackgroundDimmingView") { dimming = view }
                if container == nil, name.hasSuffix("ControlsView"), name.hasPrefix("AV") { container = view }
                if dimming == nil || container == nil { view.subviews.forEach(walk) }
            }
            walk(root)
            if let dimming { return dimming.alpha > 0.4 }
            if let container { return !container.isHidden }
            return nil
        }

        /// nil when the asset has a video track the phone can decode, otherwise what is wrong with it.
        private static func videoProblem(of asset: AVAsset) async -> String? {
            guard let tracks = try? await asset.loadTracks(withMediaType: .video) else { return nil }
            if tracks.isEmpty { return "The file has no video, only sound." }
            for track in tracks {
                if (try? await track.load(.isDecodable)) ?? true { return nil }
            }
            var codec = "unknown"
            if let first = tracks.first, let formats = try? await first.load(.formatDescriptions), let format = formats.first {
                let code = CMFormatDescriptionGetMediaSubType(format)
                codec = String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii) ?? "unknown"
            }
            return "This iPhone cannot decode the video (format \(codec.trimmingCharacters(in: .whitespaces)))."
        }

        func stop() {
            controlsTimer?.invalidate()
            controlsTimer = nil
            watchdog?.invalidate()
            watchdog = nil
            if let player, let item = player.currentItem {
                let d = item.duration.seconds
                if d.isFinite, d > 0 { parent.onProgress(player.currentTime().seconds, d) }
            }
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            if let clockObserver { player?.removeTimeObserver(clockObserver) }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            statusObservation?.invalidate()
            player?.pause()
            player = nil
            megaLoader?.cancelAll()
            megaLoader = nil
        }
    }
}

// MARK: - Web views

/// Lets pages built for the TV app talk to us: their window.parent.postMessage(...) arrives here.
private let parentShim = """
(function () {
  try {
    window.parent = { postMessage: function (m) {
      try { window.webkit.messageHandlers.cineflix.postMessage(JSON.parse(JSON.stringify(m))); } catch (e) {}
    } };
  } catch (e) {}
})();
"""

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

/// Reads the page's main video clock (in every frame) so subtitles stay in sync without any change to the page.
private let clockScript = """
(function () {
  if (window.__cfClock) return; window.__cfClock = true;
  // The page starts silent: while the app looks for its stream the page is out of sight and must not be heard.
  if (window.__cfMute === undefined) window.__cfMute = true;
  function applyMute() {
    document.querySelectorAll('video,audio').forEach(function (v) {
      if (window.__cfMute) { if (!v.muted) { v.muted = true; v.__cfSilenced = true; } }
      else if (v.__cfSilenced) { v.muted = false; v.__cfSilenced = false; }
    });
  }
  // While the page is out of sight, press its play button (muted): many players only load the real video once play is pressed.
  var nudges = 0;
  var PLAY = ['.plyr__control--overlaid', '.vjs-big-play-button', '.jw-icon-display', '.jw-display-icon-container', '.mejs__overlay-button', '.fp-play', '.ytp-large-play-button', '.dplayer-mobile-play', '.art-state', '[class*="big-play"]', '[class*="bigplay"]', '[class*="play-btn"]', '[class*="play_btn"]', '[class*="playbtn"]', '[class*="play-button"]', '[class*="play_button"]', '[class*="playButton"]', '[aria-label="Play" i]', '[title="Play" i]', 'button[class*="play" i]'];
  function nudge() {
    if (!window.__cfMute) return;
    var started = false;
    document.querySelectorAll('video').forEach(function (v) {
      if (!v.paused && v.readyState >= 2) started = true;
      else if (v.paused && !v.ended) { try { v.muted = true; var p = v.play(); if (p && p.catch) p.catch(function () {}); } catch (e) {} }
    });
    if (started || nudges++ > 40) return;
    if (nudges % 3 !== 1) return;
    for (var i = 0; i < PLAY.length; i++) {
      var els; try { els = document.querySelectorAll(PLAY[i]); } catch (e) { continue; }
      for (var k = 0; k < els.length; k++) {
        var el = els[k], r = el.getBoundingClientRect();
        if (el.__cfPressed || r.width < 8 || r.height < 8) continue;
        // Only things that say "play" and nothing else (not a playlist, a replay, the player itself or autoplay).
        var label = ((el.className && el.className.baseVal === undefined ? el.className : '') + ' ' + (el.getAttribute('aria-label') || '') + ' ' + (el.title || '')).toLowerCase();
        if (/playlist|playback|replay|player|display|autoplay|playing/.test(label) && !/big-play|overlaid/.test(label)) continue;
        el.__cfPressed = true;
        try { el.click(); } catch (e) {}
        return;
      }
    }
  }
  function pick() {
    var best = null, area = -1;
    document.querySelectorAll('video').forEach(function (v) {
      var r = v.getBoundingClientRect(), a = r.width * r.height;
      if (a > area) { area = a; best = v; }
    });
    return best ? { v: best, area: area } : null;
  }
  // The app draws subtitles over the page, but the iPhone's own full screen player covers the app. So the
  // same lines are also given to the video as a text track, which that player draws itself.
  var rev = 0, cues = [];
  function fullscreen(v) {
    return v.webkitPresentationMode === 'fullscreen' || !!v.webkitDisplayingFullscreen || !!document.fullscreenElement || !!document.webkitFullscreenElement;
  }
  function apply(v) {
    var t = v.__cfTrack;
    if (!t) {
      if (!cues.length) return;
      t = v.__cfTrack = v.addTextTrack('subtitles', 'CineFlix', 'en');
      v.__cfRev = -1;
    }
    if (v.__cfRev !== rev) {
      v.__cfRev = rev;
      var old = t.cues ? Array.prototype.slice.call(t.cues) : [];
      old.forEach(function (c) { t.removeCue(c); });
      cues.forEach(function (c) { try { t.addCue(new VTTCue(c[0], c[1], c[2])); } catch (e) {} });
    }
    var want = cues.length && fullscreen(v) ? 'showing' : 'hidden';
    if (t.mode !== want) t.mode = want;
  }
  window.__cfCues = function (r, list) {
    rev = r; cues = list || [];
    document.querySelectorAll('video').forEach(apply);
  };
  setInterval(function () {
    applyMute();
    nudge();
    var p = pick();
    if (!p || !isFinite(p.v.currentTime)) {
      // No video here (yet): still say whether this frame is muted, so a late frame gets the app's current state.
      try { window.webkit.messageHandlers.cineflixClock.postMessage({ idle: true, mute: !!window.__cfMute, rev: rev }); } catch (e) {}
      return;
    }
    try {
      var v = p.v;
      apply(v);
      // Not moving = paused, ended, seeking or buffering.
      var stopped = v.paused || v.ended || v.seeking || v.readyState < 3;
      window.webkit.messageHandlers.cineflixClock.postMessage({ position: v.currentTime, paused: stopped, weight: p.area + (stopped ? 0 : 1), rev: rev, mute: !!window.__cfMute });
    } catch (e) {}
  }, 250);
})();
"""

private func makeWebView(handler: WKScriptMessageHandler, clock: Bool = false, streams: Bool = false) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.allowsPictureInPictureMediaPlayback = true
    config.userContentController.addUserScript(WKUserScript(source: parentShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    config.userContentController.add(WeakHandler(handler), name: "cineflix")
    if clock {
        config.userContentController.addUserScript(WKUserScript(source: clockScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        config.userContentController.add(WeakHandler(handler), name: "cineflixClock")
    }
    if streams {
        // At document start, in every frame, so the hooks are in place before the page's own scripts make their first request.
        config.userContentController.addUserScript(WKUserScript(source: streamDetectScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(WeakHandler(handler), name: "cineflixStream")
    }
    let web = WKWebView(frame: .zero, configuration: config)
    web.isOpaque = false
    web.backgroundColor = .black
    web.scrollView.backgroundColor = .black
    web.scrollView.contentInsetAdjustmentBehavior = .never
    return web
}

/// Your server's player page. With tools/makeflix-page-bridge.js it reports progress and the end of playback.
struct WebPlayerView: UIViewRepresentable {
    let url: URL
    let cues: [SubtitleCue]
    let offset: Double
    let resume: Double
    let control: WebPageControl
    let onProgress: (Double, Double) -> Void
    let onClock: (Double, Bool, Double) -> Void
    let onEnd: () -> Void
    let onClose: () -> Void
    /// A stream address the page loaded its media from (see `streamDetectScript`).
    let onStream: (DetectedStream) -> Void
    var onTrace: ((String, Bool) -> Void)?
    var onTouch: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let web = makeWebView(handler: context.coordinator, clock: true, streams: true)
        if let onTouch { web.addGestureRecognizer(TouchWatcher(onTouch)) }
        control.web = web
        let coordinator = context.coordinator
        control.mute = { [weak web, weak coordinator] on in if let web { coordinator?.setMuted(on, web: web) } }
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.setCues(cues, offset: offset, web: web)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: WebPlayerView
        init(_ parent: WebPlayerView) { self.parent = parent }

        private var cueKey = ""
        private var rev = 0
        private var script = ""
        private weak var web: WKWebView?

        /// Sends the subtitle lines to every frame that has a video, so they also show in the full screen player.
        func setCues(_ cues: [SubtitleCue], offset: Double, web: WKWebView) {
            let key = "\(cues.count):\(cues.first?.start ?? 0):\(offset)"
            guard key != cueKey else { return }
            cueKey = key
            self.web = web
            rev += 1
            let list = cues.compactMap { c -> [Any]? in
                let end = c.end - offset
                return end > 0 ? [max(0, c.start - offset), end, c.text] : nil
            }
            let json = (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            script = "window.__cfCues && window.__cfCues(\(rev), \(json));"
            frames.values.forEach { push(to: $0) }
        }

        private var frames: [String: WKFrameInfo] = [:]

        /// What each frame of the page has loaded. The player may sit in an iframe, so every frame reports on its own and they are shown together.
        private var traces: [String: [String]] = [:]
        private var requestCounts: [String: Int] = [:]

        func reportTrace(_ lines: [String], _ body: [String: Any], from frame: WKFrameInfo) {
            let key = frame.request.url?.host ?? "page"
            traces[key] = lines
            let count = (body["n"] as? NSNumber)?.intValue ?? 0
            let active = count != requestCounts[key, default: 0] || (body["loading"] as? Bool) == true
            requestCounts[key] = count
            let text = traces.count <= 1 ? lines.joined(separator: "\n")
                : traces.sorted { $0.key < $1.key }.map { "[" + $0.key + "]\n" + $0.value.joined(separator: "\n") }.joined(separator: "\n")
            parent.onTrace?(text, active)
        }

        /// The page starts silent (it is hidden while the app looks for its stream). Once the page is shown the app
        /// stops touching its sound, in every frame, including frames and reloads that appear later.
        private var muted = true

        func setMuted(_ on: Bool, web: WKWebView) {
            muted = on
            let script = "window.__cfMute = \(on);"
            web.evaluateJavaScript(script) { _, _ in }
            frames.values.forEach { web.evaluateJavaScript(script, in: $0, in: .page) { _ in } }
        }

        private func push(to frame: WKFrameInfo) {
            web?.evaluateJavaScript(script, in: frame, in: .page) { _ in }
        }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "cineflixStream" {
                if let body = message.body as? [String: Any] {
                    if let lines = body["trace"] as? [String] { reportTrace(lines, body, from: message.frameInfo) }
                    else if let found = DetectedStream(message: body) { parent.onStream(found) }
                }
                return
            }
            if message.name == "cineflixClock", let body = message.body as? [String: Any] {
                if let reported = body["mute"] as? Bool, reported != muted {
                    web?.evaluateJavaScript("window.__cfMute = \(muted);", in: message.frameInfo, in: .page) { _ in }
                }
                if (body["idle"] as? Bool) == true {
                    let seen = (body["rev"] as? NSNumber)?.intValue ?? 0
                    frames[message.frameInfo.request.url?.absoluteString ?? ""] = message.frameInfo
                    if rev > 0, seen != rev { push(to: message.frameInfo) }
                    return
                }
                let pos = (body["position"] as? NSNumber)?.doubleValue ?? 0
                let paused = (body["paused"] as? Bool) ?? true
                let weight = (body["weight"] as? NSNumber)?.doubleValue ?? 1
                parent.onClock(pos, paused, weight)
                // A frame that has not heard the current lines (new, or reloaded) gets them now.
                let seen = (body["rev"] as? NSNumber)?.intValue ?? 0
                let id = message.frameInfo.request.url?.absoluteString ?? ""
                frames[id] = message.frameInfo
                if rev > 0, seen != rev { push(to: message.frameInfo) }
                return
            }
            guard let body = message.body as? [String: Any], (body["source"] as? String) == "makeflix-page" else { return }
            switch body["type"] as? String {
            case "progress":
                let pos = (body["position"] as? NSNumber)?.doubleValue ?? 0
                let dur = (body["duration"] as? NSNumber)?.doubleValue ?? 0
                if dur > 0 { parent.onProgress(pos, dur) }
            case "ended": parent.onEnd()
            case "back", "close": parent.onClose()
            default: break
            }
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            guard parent.resume > 5 else { return }
            // Seek the page's main <video> to the saved position once it has metadata.
            let js = """
            (function (t) { var n = 0; function go() {
              var v = document.querySelector('video');
              if (v && v.readyState > 0 && v.duration) { v.currentTime = Math.min(t, v.duration - 10); return; }
              if (n++ < 60) setTimeout(go, 500);
            } go(); })(\(parent.resume));
            """
            web.evaluateJavaScript(js)
        }
    }
}

// MARK: - Trailer

/// YouTube trailers through the hosted trailer page (avoids YouTube error 153), with touch controls.
struct TrailerScreen: View {
    let videoKey: String
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var controller = TrailerController()
    @State private var paused = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TrailerWebView(url: trailerURL, controller: controller, onEnd: { dismiss() })
                .ignoresSafeArea()

            // Touch layer: the embedded player has no controls of its own.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    controller.send("toggle")
                    paused.toggle()
                }
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 38)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close")
                    Spacer()
                }
                Spacer()
                HStack(spacing: 28) {
                    Button { controller.send("seek", -10) } label: { Image(systemName: "gobackward.10") }
                    Button {
                        controller.send("toggle")
                        paused.toggle()
                    } label: { Image(systemName: paused ? "play.fill" : "pause.fill").contentTransition(.symbolEffect(.replace)) }
                    Button { controller.send("seek", 10) } label: { Image(systemName: "goforward.10") }
                }
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: Capsule())
            }
            .padding(16)
        }
        .statusBarHidden()
    }

    private var trailerURL: URL? {
        var comps = URLComponents(string: settings.trailerPage)
        comps?.queryItems = [URLQueryItem(name: "v", value: videoKey)]
        return comps?.url
    }
}

@Observable
final class TrailerController {
    @ObservationIgnored weak var webView: WKWebView?

    func send(_ cmd: String, _ value: Double = 0) {
        webView?.evaluateJavaScript("window.postMessage({source:'mf-app',cmd:'\(cmd)',value:\(value)},'*')")
    }
}

private struct TrailerWebView: UIViewRepresentable {
    let url: URL?
    let controller: TrailerController
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEnd: onEnd) }

    func makeUIView(context: Context) -> WKWebView {
        let web = makeWebView(handler: context.coordinator)
        web.isUserInteractionEnabled = false
        controller.webView = web
        if let url { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.finished = true
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.stopLoading()
        web.pauseAllMediaPlayback()
        web.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onEnd: () -> Void
        /// Set once the trailer is over or closed, so a late message from the page can never start or end anything again.
        var finished = false
        init(onEnd: @escaping () -> Void) { self.onEnd = onEnd }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !finished, let body = message.body as? [String: Any], (body["source"] as? String) == "mf-trailer" else { return }
            if body["type"] as? String == "ended" || (body["type"] as? String == "state" && (body["state"] as? NSNumber)?.intValue == 0) {
                finished = true
                onEnd()
            }
        }
    }
}
