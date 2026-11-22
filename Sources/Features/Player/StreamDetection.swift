import AVFoundation
import Foundation
import WebKit

/// Finds the real stream behind a media server's HTML player page.
///
/// Such pages usually play through MediaSource (hls.js, MSE) into a `blob:` address. The iPhone can send audio from that to an AirPlay
/// receiver but not the picture, because there is no web address to hand over. The script below runs in every frame of the page, watches
/// where the page loads its media from and reports the likely stream address. The player screen then offers "Play natively", which plays
/// that address with AVPlayer, where AirPlay and Chromecast carry the picture.
///
/// This is detection by observation: it only sees what a page does through XMLHttpRequest, fetch, `src` properties or hls.js. A page that
/// builds its requests some other way (a worker, WebAssembly, a protected stream) is not seen, and a stream that needs more than the
/// Referer, User-Agent and cookies of the page will not play natively either. None of this could be tried against a real server page.
let streamDetectScript = """
(function () {
  if (window.__cfStreams) return; window.__cfStreams = true;
  var seen = {};
  // What the page loads, in a few words per request, so a page whose stream is not found can be understood (shown by the app on failure).
  var trace = [], traceKeys = {}, mseAppends = 0, requests = 0, cands = 0, lastSig = '';
  function tail(u) { try { var p = new URL(u).pathname.split('/').filter(Boolean); var t = p[p.length - 1] || '/'; return t.length > 26 ? t.slice(0, 12) + '..' + t.slice(-10) : t; } catch (e) { return '?'; } }
  function pushTrace(line) {
    if (trace.length >= 14 || traceKeys[line]) return;
    traceKeys[line] = 1; trace.push(line);
  }
  function note(kind, u, status, type, size) {
    requests++;
    if (/\\.(js|css|woff2?|ttf|svg|ico|html?)(\\?|#|$)/i.test(u)) return;
    var t = (type || '').split(';')[0] || 'no type';
    pushTrace(kind + ' ' + status + ' ' + tail(u) + ' ' + t + (size ? ' ' + (size > 1048576 ? (size / 1048576).toFixed(1) + 'MB' : size > 1024 ? Math.round(size / 1024) + 'KB' : size + 'B') : ''));
  }
  function sizeOf(len, range) { var m = range && /\\/(\\d+)$/.exec(range); return m ? Number(m[1]) : (len ? Number(len) : 0); }
  try {
    if (window.MediaSource) {
      var asb = MediaSource.prototype.addSourceBuffer;
      MediaSource.prototype.addSourceBuffer = function (mime) { pushTrace('MSE ' + mime); return asb.apply(this, arguments); };
      var app = SourceBuffer.prototype.appendBuffer;
      SourceBuffer.prototype.appendBuffer = function () { mseAppends++; if (mseAppends === 1 || mseAppends % 20 === 0) pushTrace('MSE appends ' + mseAppends); return app.apply(this, arguments); };
    }
  } catch (e) {}
  var SKIP = /\\.(ts|m4s|m4f|m4a|aac|mp3|vtt|webvtt|srt|key|cmfv|cmfa|mpd|jpe?g|png|gif|webp|svg|js|css|json|woff2?)(\\?|#|$)/i;
  var FILES = { mp4: 1, webm: 1, mov: 1, m4v: 1 };
  function abs(u) { try { return new URL(String(u), location.href).href; } catch (e) { return null; } }
  function ext(u) { try { var m = /\\.([a-z0-9]+)$/.exec(new URL(u).pathname.toLowerCase()); return m ? m[1] : ''; } catch (e) { return ''; } }
  function web(u) { return u && /^https?:/i.test(u); }
  function report(u, kind, variants) {
    var key = kind + '|' + u;
    if (seen[key]) return;
    seen[key] = 1;
    try {
      window.webkit.messageHandlers.cineflixStream.postMessage({ url: u, kind: kind, variants: variants || [], referer: location.href, ua: navigator.userAgent });
    } catch (e) {}
  }
  // An address that is certainly media (it was given to a video element) or may be (named in the page's own data) but whose kind is not
  // known by its name. The app looks at the first bytes itself and decides.
  function candidate(u) {
    if (!web(u) || cands >= 30) return;
    if (seen['candidate|' + u]) return;
    cands++;
    report(u, 'candidate');
  }
  // Stream addresses that the page's own JSON answers name, for example {"source":"https:\\/\\/host\\/video\\/master.m3u8"}.
  function scanJson(t) {
    if (typeof t !== 'string' || t.length > 1500000) return;
    var re = /https?:\\/\\/[^"'\\s<>\\\\]+?\\.(?:m3u8|mp4|webm|mov)(?:\\?[^"'\\s<>\\\\]*)?/gi, m, n = 0;
    t = t.replace(/\\\\\\//g, '/');
    while ((m = re.exec(t)) && n++ < 6) candidate(m[0]);
  }
  // Loads that the browser makes for a video element itself never pass through fetch or XMLHttpRequest; the resource timeline lists them.
  try {
    new PerformanceObserver(function (list) {
      list.getEntries().forEach(function (en) {
        if (!/^(video|audio|source|track|other)$/.test(en.initiatorType) || !web(en.name) || /\\.(js|css|woff2?|svg|png|jpe?g|gif|webp|ico|html?|json)(\\?|#|$)/i.test(en.name)) return;
        var e = ext(en.name);
        if (e === 'm3u8') report(en.name, 'hls'); else if (FILES[e]) report(en.name, 'file'); else candidate(en.name);
      });
    }).observe({ type: 'resource', buffered: true });
  } catch (e) {}
  // A master playlist lists variants (#EXT-X-STREAM-INF) and renditions (URI="..."); a media playlist lists segments (#EXTINF).
  function sniff(u, text) {
    var kind = 'hls', variants = [];
    if (typeof text === 'string') try {
      if (text.indexOf('#EXT-X-STREAM-INF') >= 0) {
        kind = 'master';
        var lines = text.split(/\\r?\\n/), next = false;
        lines.forEach(function (l) {
          l = l.trim();
          if (l.indexOf('#EXT-X-STREAM-INF') === 0) { next = true; return; }
          var m = /URI="([^"]+)"/.exec(l);
          if (l.charAt(0) === '#') { if (m) { var a = new URL(m[1], u).href; variants.push(a); } return; }
          if (next && l) { variants.push(new URL(l, u).href); next = false; }
        });
        variants = variants.slice(0, 200);
      } else if (text.indexOf('#EXTINF') >= 0) kind = 'media';
    } catch (e) {}
    report(u, kind, variants);
  }
  function inspect(u, type, text) {
    if (!web(u)) return;
    var e = ext(u), hls = e === 'm3u8' || /mpegurl/i.test(type || '');
    // A playlist is recognised by what it says, not by its name: servers call them .txt, .php or nothing at all.
    if (!hls && text) { var t = null; try { t = text(); } catch (x) {} if (typeof t === 'string' && /^\\uFEFF?\\s*#EXTM3U/.test(t.slice(0, 16))) { sniff(u, t); return; } }
    if (hls) { sniff(u, text ? text() : null); return; }
    if (SKIP.test(u)) return;
    if (FILES[e] || /^video\\/(mp4|webm|quicktime)/i.test(type || '')) report(u, 'file');
  }
  // Addresses a page assigns itself: a plain .m3u8 or video file (a blob: address is skipped, there is nothing to play from it).
  function assigned(v) {
    var u = abs(v);
    if (!web(u)) return;
    var e = ext(u);
    if (e === 'm3u8') report(u, 'hls'); else if (FILES[e]) report(u, 'file'); else if (!SKIP.test(u)) candidate(u);
  }

  try {
    var open = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      var x = this, u = abs(url);
      try {
        x.addEventListener('load', function () {
          if (x.status < 200 || x.status >= 300) return;
          var fin = x.responseURL || u;
          try { note('xhr', fin, x.status, x.getResponseHeader('content-type'), sizeOf(x.getResponseHeader('content-length'), x.getResponseHeader('content-range'))); } catch (e) {}
          try { if (/json/i.test(x.getResponseHeader('content-type') || '') && (x.responseType === '' || x.responseType === 'text')) scanJson(x.responseText); } catch (e) {}
          inspect(fin, x.getResponseHeader('content-type'), function () { return x.responseType === '' || x.responseType === 'text' ? x.responseText : null; });
        });
      } catch (e) {}
      return open.apply(this, arguments);
    };
  } catch (e) {}

  try {
    var realFetch = window.fetch;
    if (realFetch) window.fetch = function (input) {
      var p = realFetch.apply(this, arguments);
      try {
        var u = abs(typeof input === 'string' ? input : (input && input.url) || input);
        p.then(function (res) {
          try {
            if (!res.ok) return;
            var fin = res.url || u, type = res.headers.get('content-type') || '';
            var len = sizeOf(res.headers.get('content-length'), res.headers.get('content-range'));
            note('fetch', fin, res.status, type, len);
            if (/json/i.test(type) && (!len || len < 1500000)) { try { res.clone().text().then(scanJson, function () {}); } catch (e) {} }
            if (ext(fin) === 'm3u8' || /mpegurl/i.test(type)) {
              res.clone().text().then(function (t) { inspect(fin, type, function () { return t; }); }, function () { inspect(fin, type, null); });
            } else if (!/^(video|audio|text\\/html|text\\/css|font)\\//i.test(type) && !/javascript|json/i.test(type) && (!len || len < 2097152) && !SKIP.test(fin) || /^(text\\/plain|application\\/octet-stream)/i.test(type)) {
              // Look at the first bytes only; read the rest if it turns out to be a playlist. Both copies are taken now: once the page has
              // read the response, it can no longer be copied.
              try {
                var full = res.clone(), rd = res.clone().body.getReader();
                rd.read().then(function (r) {
                  try { rd.cancel(); } catch (e) {}
                  var head = ''; if (r && r.value) for (var i = 0; i < Math.min(12, r.value.length); i++) head += String.fromCharCode(r.value[i]);
                  if (head.indexOf('#EXTM3U') >= 0) full.text().then(function (t) { inspect(fin, type, function () { return t; }); }, function () {});
                  else { try { full.body.cancel(); } catch (e) {} inspect(fin, type, null); }
                }, function () { inspect(fin, type, null); });
              } catch (e) { inspect(fin, type, null); }
            } else inspect(fin, type, null);
          } catch (e) {}
        }, function () {});
      } catch (e) {}
      return p;
    };
  } catch (e) {}

  function watch(proto, name) {
    try {
      var d = Object.getOwnPropertyDescriptor(proto, name);
      if (d && d.set) Object.defineProperty(proto, name, { configurable: true, enumerable: d.enumerable, get: d.get, set: function (v) { try { assigned(v); } catch (e) {} return d.set.call(this, v); } });
    } catch (e) {}
  }
  watch(HTMLMediaElement.prototype, 'src');
  watch(HTMLSourceElement.prototype, 'src');
  try {
    var setAttribute = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function (n, v) {
      try { if (String(n).toLowerCase() === 'src' && /^(VIDEO|AUDIO|SOURCE)$/.test(this.tagName)) assigned(v); } catch (e) {}
      return setAttribute.apply(this, arguments);
    };
  } catch (e) {}

  // hls.js: loadSource(url) names the master playlist directly.
  function wrapHls(H) {
    try {
      if (!H || !H.prototype || H.prototype.__cfWrapped || typeof H.prototype.loadSource !== 'function') return;
      var load = H.prototype.loadSource;
      H.prototype.loadSource = function (u) { try { assigned(u); } catch (e) {} return load.apply(this, arguments); };
      H.prototype.__cfWrapped = true;
    } catch (e) {}
  }
  try {
    var hls = window.Hls;
    Object.defineProperty(window, 'Hls', { configurable: true, get: function () { return hls; }, set: function (v) { hls = v; wrapHls(v); } });
  } catch (e) {}

  // <source> elements and video tags written into the page's HTML, and a late hls.js.
  // Once a second: how the page's video element and frames are doing, so the app can tell a page that is still busy from one that is stuck.
  function status() {
    try {
      var vs = document.querySelectorAll('video'), vline = '', loading = false;
      if (vs.length) {
        var v0 = vs[0], src = v0.currentSrc || v0.getAttribute('src') || '';
        vline = 'video ' + (src ? tail(src) : 'no src') + ' ready ' + v0.readyState + ' net ' + v0.networkState + (v0.error ? ' error ' + v0.error.code : '');
        loading = v0.networkState === 2;
      }
      var fr = document.querySelectorAll('iframe'), fline = '';
      if (fr.length) fline = 'iframes ' + Array.prototype.map.call(fr, function (f) { try { return new URL(f.src).host; } catch (e) { return 'inline'; } }).slice(0, 3).join(' ');
      var lines = trace.slice();
      if (fline) lines.push(fline);
      if (vline) lines.push(vline);
      if (mseAppends) lines.push('MSE appended ' + mseAppends + ' pieces');
      var sig = requests + '|' + lines.join('|');
      if (sig === lastSig) return;
      lastSig = sig;
      window.webkit.messageHandlers.cineflixStream.postMessage({ trace: lines, n: requests, loading: loading });
    } catch (e) {}
  }
  setInterval(function () {
    wrapHls(window.Hls);
    status();
    var els = document.querySelectorAll('video, audio, source');
    for (var i = 0; i < els.length; i++) { var u = els[i].currentSrc || els[i].getAttribute('src'); if (u) assigned(u); }
  }, 1000);
})();
"""

/// A stream address found on the page, with what the page sent when it loaded it.
struct DetectedStream: Equatable {
    /// How sure we are that this address is the thing to play. The higher, the better.
    enum Kind: Int {
        /// Not yet looked at: the app reads the first bytes to find out what it is (never offered to the picker as it is).
        case candidate = 0
        case media = 1      // one quality of an HLS stream
        case file = 3       // .mp4, .webm, .mov
        case hls = 4        // an .m3u8 whose type could not be read
        case master = 5     // an HLS master playlist
    }

    var url: URL
    var kind: Kind
    /// For a master playlist: the quality and rendition playlists it names, so those are not mistaken for the stream itself.
    var variants: Set<URL> = []
    var referer: String?
    var userAgent: String?

    /// Reads the script's message.
    init?(message body: [String: Any]) {
        guard let text = body["url"] as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        switch body["kind"] as? String {
        case "master": kind = .master
        case "media": kind = .media
        case "file": kind = .file
        case "hls": kind = .hls
        case "candidate": kind = .candidate
        default: return nil
        }
        self.url = url
        variants = Set((body["variants"] as? [String] ?? []).compactMap(URL.init(string:)))
        referer = body["referer"] as? String
        userAgent = body["ua"] as? String
    }

    init(url: URL, kind: Kind, variants: Set<URL> = [], referer: String? = nil, userAgent: String? = nil) {
        self.url = url
        self.kind = kind
        self.variants = variants
        self.referer = referer
        self.userAgent = userAgent
    }
}

/// Keeps the best stream seen so far: a master playlist beats its own quality playlists, and a file or playlist found later replaces
/// an earlier one of the same or lower rank (the page moved on to another video).
struct StreamPicker {
    private(set) var best: DetectedStream?
    /// Addresses that turned out not to be a whole video (a tiny file: the initialisation piece of a stream the page assembles itself).
    private var rejected: Set<URL> = []
    private var probed: Set<URL> = []
    /// Why addresses were turned down, for the note shown when nothing playable was found.
    private(set) var rejectedNotes: [String] = []

    @discardableResult
    mutating func offer(_ found: DetectedStream) -> Bool {
        if rejected.contains(found.url) { return false }
        if let best {
            if best.url == found.url { self.best = found; return best != found }
            if best.kind == .master, best.variants.contains(found.url) { return false }
            // A quality playlist that its own master did not name belongs to something new, anything else must rank at least as high.
            if found.kind.rawValue < best.kind.rawValue, !(found.kind == .media && best.kind == .master) { return false }
        }
        best = found
        return true
    }

    mutating func shouldProbe(_ url: URL) -> Bool { probed.count < 40 && probed.insert(url).inserted }

    mutating func reject(_ url: URL, because why: String = "") {
        if !why.isEmpty, rejectedNotes.count < 4 { rejectedNotes.append(why) }
        rejected.insert(url)
        if best?.url == url { best = nil }
    }

    mutating func reset() { best = nil; rejected = []; probed = []; rejectedNotes = [] }
}

/// What the native player needs to load the address the way the page did.
struct NativeStream: Equatable {
    var url: URL
    var referer: String?
    var userAgent: String?
    var cookies: [HTTPCookie] = []

    /// AVURLAsset options. "AVURLAssetHTTPHeaderFieldsKey" is the long-standing key for extra request headers; Apple does not declare it
    /// in the SDK headers, so it is spelled out here. It is applied to the playlist and segment requests the phone makes itself.
    var assetOptions: [String: Any] {
        var options: [String: Any] = [:]
        if let referer { options["AVURLAssetHTTPHeaderFieldsKey"] = ["Referer": referer] }
        if let userAgent { options[AVURLAssetHTTPUserAgentKey] = userAgent }
        if !cookies.isEmpty { options[AVURLAssetHTTPCookiesKey] = cookies }
        return options
    }

    /// The same, as headers, for the Chromecast proxy that fetches the stream for the TV.
    var proxyHeaders: [String: String] {
        var headers: [String: String] = [:]
        if let referer { headers["Referer"] = referer }
        if let userAgent { headers["User-Agent"] = userAgent }
        if !cookies.isEmpty { headers.merge(HTTPCookie.requestHeaderFields(with: cookies)) { $1 } }
        return headers
    }
}

/// Lets the player screen reach the web view that shows the page (to read its cookies).
final class WebPageControl {
    weak var web: WKWebView?
    /// Silences (or restores) the page's video while it is open out of sight.
    var mute: ((Bool) -> Void)?

    /// Cookies the page's browser holds that apply to `url`.
    func cookies(for url: URL) async -> [HTTPCookie] {
        guard let store = web?.configuration.websiteDataStore.httpCookieStore, let host = url.host()?.lowercased() else { return [] }
        let secure = url.scheme?.lowercased() == "https"
        return await store.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == domain || host.hasSuffix("." + domain)) && url.path.hasPrefix(cookie.path) && (secure || !cookie.isSecure)
        }
    }
}
