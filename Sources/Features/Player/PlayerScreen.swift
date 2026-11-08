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

    enum Phase { case resolving, video(URL), mega(MegaDownload), page(URL), failed(String) }
    @State private var phase: Phase = .resolving

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            switch phase {
            case .resolving:
                VStack(spacing: 14) {
                    ProgressView().tint(.white).controlSize(.large)
                    Text(request.title).font(.headline)
                    if let s = request.subtitle { Text(s).font(.subheadline).foregroundStyle(Theme.dim) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .video(let url):
                VideoPlayerView(subtitles: subtitles, url: url, resume: request.resume, onProgress: save, onClock: { subtitles.setClock(position: $0, paused: $1) }, onEnd: ended)
                    .ignoresSafeArea()
                    .id(request.id)
            case .mega(let dl):
                VideoPlayerView(subtitles: subtitles, url: dl.url, mega: dl, resume: 0, onProgress: { _, _ in }, onClock: { _, _ in }, onEnd: ended)
                    .ignoresSafeArea()
                    .id(request.id)
            case .page(let url):
                WebPlayerView(url: url, cues: subtitles.cues, offset: subtitles.offset, resume: request.resume, onProgress: save,
                              onClock: { subtitles.setClock(position: $0, paused: $1, weight: $2) }, onEnd: ended, onClose: { dismiss() })
                    .ignoresSafeArea()
                    .id(request.id)
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Theme.text2)
                    Text(message).multilineTextAlignment(.center).foregroundStyle(Theme.text2)
                    Button("Close") { dismiss() }.buttonStyle(.glass)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !isNativeVideo { SubtitleOverlay(controller: subtitles) }

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
                Spacer()
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
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .sheet(isPresented: $showSubtitles) { SubtitleSheet(request: request, controller: subtitles) }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task(id: request.id) { await resolve() }
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
        phase = .resolving
        loadSavedSubtitle()
        do {
            if let m = request.mega {
                phase = .mega(try await megaDownload(m))
                return
            }
            let found: Playback
            if let link = request.link { found = try await settings.server.resolveLink(link) }
            else { found = try await settings.server.resolve(request.ref, season: request.season, episode: request.episode) }
            switch found {
            case .video(let url): phase = .video(url)
            case .page(let url): phase = .page(url)
            }
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

    private func ended() {
        if let m = request.mega { playNextMega(after: m); return }
        guard request.ref.type == .tv, let s = request.season, let e = request.episode else {
            dismiss()
            return
        }
        Task {
            if let next = await settings.tmdb.nextEpisode(showID: request.ref.id, season: s, episode: e) {
                var r = request
                r = PlaybackRequest(ref: r.ref, season: next.season, episode: next.episode.episodeNumber, title: r.title,
                                    subtitle: next.episode.name, backdropPath: r.backdropPath, posterPath: r.posterPath,
                                    stillPath: next.episode.stillPath, resume: 0, item: r.item)
                request = r
            } else {
                dismiss()
            }
        }
    }
}

extension PlayerScreen {
    /// After a file in a MEGA folder, the next playable video in the same folder.
    fileprivate func playNextMega(after m: MegaPlay) {
        Task {
            guard let link = MegaLink.parse(m.linkText), let folder = try? await MegaStore.shared.folder(for: link),
                  let node = folder.node(m.node) else { dismiss(); return }
            let siblings = folder.children(of: node.parent).filter { !$0.isDir && MegaFormat.playsOnPhone($0.name) }
            guard let at = siblings.firstIndex(where: { $0.id == node.id }), at + 1 < siblings.count else { dismiss(); return }
            let next = siblings[at + 1]
            request = PlaybackRequest(ref: request.ref, title: (next.name as NSString).deletingPathExtension, subtitle: request.subtitle,
                                      mega: MegaPlay(linkText: m.linkText, node: next.id))
        }
    }
}

// MARK: - Native player

struct VideoPlayerView: UIViewControllerRepresentable {
    let subtitles: SubtitleController
    let url: URL
    var mega: MegaDownload?
    let resume: Double
    let onProgress: (Double, Double) -> Void
    let onClock: (Double, Bool) -> Void
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.player = context.coordinator.start()
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
                item = AVPlayerItem(url: parent.url)
            }
            let player = AVPlayer(playerItem: item)
            self.player = player

            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, item.status == .readyToPlay, !self.didSeek else { return }
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

        func stop() {
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
    var p = pick();
    if (!p || !isFinite(p.v.currentTime)) return;
    try {
      var v = p.v;
      apply(v);
      // Not moving = paused, ended, seeking or buffering.
      var stopped = v.paused || v.ended || v.seeking || v.readyState < 3;
      window.webkit.messageHandlers.cineflixClock.postMessage({ position: v.currentTime, paused: stopped, weight: p.area + (stopped ? 0 : 1), rev: rev });
    } catch (e) {}
  }, 250);
})();
"""

private func makeWebView(handler: WKScriptMessageHandler, clock: Bool = false) -> WKWebView {
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
    let onProgress: (Double, Double) -> Void
    let onClock: (Double, Bool, Double) -> Void
    let onEnd: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let web = makeWebView(handler: context.coordinator, clock: true)
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

        private func push(to frame: WKFrameInfo) {
            web?.evaluateJavaScript(script, in: frame, in: .page) { _ in }
        }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "cineflixClock", let body = message.body as? [String: Any] {
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
