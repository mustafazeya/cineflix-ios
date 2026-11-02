import Foundation
import Observation
import Compression

struct SubtitleCue: Hashable, Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct SubtitleResult: Identifiable, Hashable, Sendable {
    let name: String
    let lang: String
    let hi: Bool
    let url: String
    let author: String
    /// True for a season pack, a zip with many episodes (or one made for other episodes).
    var pack = false

    var id: String { url }
}

enum SubtitleError: LocalizedError {
    case badKey
    case http(Int)
    case noFile
    case noEpisode(Int)
    case empty
    case limit

    var errorDescription: String? {
        switch self {
        case .badKey: "SubDL did not accept your API key. Check it in Settings."
        case .http(let code): "Subtitle request failed (\(code))."
        case .noFile: "No subtitle file inside the download."
        case .noEpisode(let n): "This pack has no file for episode \(n). Try another result."
        case .empty: "This subtitle file is empty or not supported."
        case .limit: "SubDL download limit reached for today."
        }
    }
}

/// Subtitle search and download through SubDL (api key from subdl.com/panel/api).
struct SubDL: Sendable {
    let key: String

    func search(_ ref: MediaRef, season: Int?, episode: Int?, languages: [String]) async throws -> [SubtitleResult] {
        var comps = URLComponents(string: "https://api.subdl.com/api/v1/subtitles")!
        var q = [URLQueryItem(name: "api_key", value: key),
                 URLQueryItem(name: "tmdb_id", value: String(ref.id)),
                 URLQueryItem(name: "type", value: ref.type.rawValue),
                 URLQueryItem(name: "languages", value: languages.joined(separator: ",")),
                 URLQueryItem(name: "subs_per_page", value: "30")]
        if ref.type == .tv, let season, let episode {
            q += [URLQueryItem(name: "season_number", value: String(season)),
                  URLQueryItem(name: "episode_number", value: String(episode))]
            // No full_season filter: most episodes only exist inside season packs, which are picked apart on download.
        }
        comps.queryItems = q
        var req = URLRequest(url: comps.url!, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if (json?["status"] as? Bool) == false {
            let msg = (json?["error"] as? String) ?? ""
            if code == 401 || code == 403 || msg.range(of: "api.?key|unauthor|invalid|forbidden", options: [.regularExpression, .caseInsensitive]) != nil {
                throw SubtitleError.badKey
            }
            return []
        }
        guard code == 200, let list = json?["subtitles"] as? [[String: Any]] else { throw SubtitleError.http(code) }

        var seen = Set<String>()
        var out: [SubtitleResult] = []
        for s in list {
            guard let url = s["url"] as? String, seen.insert(url).inserted else { continue }
            out.append(SubtitleResult(
                name: (s["release_name"] as? String) ?? (s["name"] as? String) ?? "Subtitle",
                lang: ((s["language"] as? String) ?? (s["lang"] as? String) ?? "").uppercased(),
                // SubDL appends the API key to download links; downloads work without it, so drop it.
                hi: (s["hi"] as? Bool) ?? false,
                url: url.replacingOccurrences(of: #"([?&])api_key=[^&]*&?"#, with: "$1", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "?&")),
                author: (s["author"] as? String) ?? "",
                pack: ref.type == .tv && Self.isPack(s, episode: episode)))
        }
        // Preferred language first, then subtitles made for this exact episode before season packs,
        // then regular before hearing-impaired.
        return out.enumerated().sorted { a, b in
            let la = languages.firstIndex(of: a.element.lang) ?? 99
            let lb = languages.firstIndex(of: b.element.lang) ?? 99
            if la != lb { return la < lb }
            if a.element.pack != b.element.pack { return !a.element.pack }
            if a.element.hi != b.element.hi { return !a.element.hi }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// A result is a season pack when SubDL says so, or when its episode range does not include this episode.
    static func isPack(_ s: [String: Any], episode: Int?) -> Bool {
        if (s["full_season"] as? Bool) == true { return true }
        func num(_ k: String) -> Int? { (s[k] as? Int) ?? (s[k] as? NSNumber)?.intValue }
        if let from = num("episode_from"), let to = num("episode_end"), from > 0, to >= from {
            guard let episode else { return false }
            return !(episode >= from && episode <= to)
        }
        return s["episode"] == nil || s["episode"] is NSNull
    }

    /// Finds the file for one episode inside a zip, trying the common naming styles.
    static func episodeFile(_ entries: [ZipReader.Entry], season: Int, episode: Int) -> ZipReader.Entry? {
        let S = "0*\(season)", E = "0*\(episode)"
        let patterns = [
            "s\(S)[ ._-]*e(?:p|pisode)?[ ._-]*\(E)(?![0-9])",
            "(?:^|[^0-9])\(S)[x.]\(E)(?![0-9])",
            "season[ ._-]*\(S)[^0-9].*episode[ ._-]*\(E)(?![0-9])",
            "(?:^|[^a-z0-9])e(?:p|pisode)?[ ._-]*\(E)(?![0-9])",
            "^[^a-z0-9]*\(E)(?![0-9])"
        ]
        let bases = entries.map { e -> String in
            let base = e.name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? e.name
            return base.replacingOccurrences(of: #"\.(srt|vtt)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        for p in patterns {
            let hits = entries.indices.filter { bases[$0].range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
            if let best = hits.max(by: { entries[$0].data.count < entries[$1].data.count }) { return entries[best] }
        }
        return nil
    }

    func download(_ r: SubtitleResult, season: Int?, episode: Int?) async throws -> (text: String, cues: [SubtitleCue]) {
        guard let url = URL(string: "https://dl.subdl.com" + r.url) else { throw SubtitleError.noFile }
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 { throw SubtitleError.limit }
        guard code == 200 else { throw SubtitleError.http(code) }

        var file = data
        if data.starts(with: [0x50, 0x4B]) {
            let entries = try ZipReader.entries(data).filter { $0.name.range(of: #"\.(srt|vtt)$"#, options: [.regularExpression, .caseInsensitive]) != nil }
            guard !entries.isEmpty else { throw SubtitleError.noFile }
            var pick = entries.max { $0.data.count < $1.data.count }!
            if let season, let episode, entries.count > 1 {
                // Packs hold several episodes: take the file for this one, never a different episode.
                if let named = Self.episodeFile(entries, season: season, episode: episode) {
                    pick = named
                } else if r.pack {
                    throw SubtitleError.noEpisode(episode)
                }
            }
            file = pick.data
        }
        let text = SubtitleParser.decode(file, lang: r.lang)
        let cues = SubtitleParser.parse(text)
        guard !cues.isEmpty else { throw SubtitleError.empty }
        return (text, cues)
    }
}

// MARK: - Parsing

enum SubtitleParser {
    static func decode(_ data: Data, lang: String) -> String {
        var s = String(data: data, encoding: .utf8)
        if s == nil {
            let encodings: [String: String.Encoding] = [
                "RU": .windowsCP1251, "UK": .windowsCP1251, "BG": .windowsCP1251,
                "EL": .windowsCP1253, "TR": .windowsCP1254,
                "PL": .windowsCP1250, "CS": .windowsCP1250, "SK": .windowsCP1250, "HU": .windowsCP1250,
                "RO": .windowsCP1250, "HR": .windowsCP1250, "SL": .windowsCP1250
            ]
            if lang == "AR" || lang == "FA" || lang == "UR" {
                let e = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue))
                s = String(data: data, encoding: String.Encoding(rawValue: e))
            } else if lang == "HE" {
                let e = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue))
                s = String(data: data, encoding: String.Encoding(rawValue: e))
            } else {
                s = String(data: data, encoding: encodings[lang] ?? .windowsCP1252)
            }
        }
        let text = s ?? String(decoding: data, as: UTF8.self)
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    static func parseTime(_ raw: String) -> Double? {
        let token = raw.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let parts = token.split(separator: ":").map(String.init)
        guard parts.count >= 2, parts.count <= 3, let last = parts.last else { return nil }
        let secParts = last.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
        guard let sec = Double(secParts.first ?? "") else { return nil }
        var frac = 0.0
        if secParts.count > 1, let f = Double("0." + secParts[1]) { frac = f }
        let mins = Double(parts[parts.count - 2]) ?? 0
        let hours = parts.count == 3 ? (Double(parts[0]) ?? 0) : 0
        return hours * 3600 + mins * 60 + sec + frac
    }

    /// SRT and WebVTT. Keeps <i>, drops every other tag and ASS-style {...} codes.
    static func parse(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[i].components(separatedBy: "-->")
            guard times.count == 2, let start = parseTime(times[0]), let end = parseTime(times[1]), end > start else { continue }
            var body = lines[(i + 1)...].joined(separator: "\n")
            body = body.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            body = body.replacingOccurrences(of: #"<(?!/?i>)[^>]*>"#, with: "", options: .regularExpression)
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func cue(in cues: [SubtitleCue], at t: Double) -> SubtitleCue? {
        var lo = 0, hi = cues.count - 1, idx = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { idx = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        var k = idx
        while k >= 0, k > idx - 4 {
            if cues[k].end > t { return cues[k] }
            k -= 1
        }
        return nil
    }

    /// <i>…</i> becomes italics.
    static func styled(_ s: String) -> AttributedString {
        var out = AttributedString()
        var italic = false
        var buf = ""
        func flush() {
            guard !buf.isEmpty else { return }
            var piece = AttributedString(buf)
            if italic { piece.inlinePresentationIntent = .emphasized }
            out.append(piece)
            buf = ""
        }
        var rest = Substring(s)
        while let c = rest.first {
            if rest.hasPrefix("<i>") { flush(); italic = true; rest = rest.dropFirst(3) }
            else if rest.hasPrefix("</i>") { flush(); italic = false; rest = rest.dropFirst(4) }
            else { buf.append(c); rest = rest.dropFirst() }
        }
        flush()
        return out
    }
}

// MARK: - Minimal ZIP reader (stored and deflate entries)

enum ZipReader {
    struct Entry { let name: String; let data: Data }

    private static func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }

    static func entries(_ d: Data) throws -> [Entry] {
        guard d.count > 22 else { throw SubtitleError.noFile }
        var eocd = -1
        var i = d.count - 22
        while i >= max(0, d.count - 22 - 65536) {
            if u32(d, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw SubtitleError.noFile }

        let count = u16(d, eocd + 10)
        var p = u32(d, eocd + 16)
        var out: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x02014b50 else { break }
            let method = u16(d, p + 10)
            let csize = u32(d, p + 20)
            let nlen = u16(d, p + 28), elen = u16(d, p + 30), clen = u16(d, p + 32)
            let local = u32(d, p + 42)
            let name = String(decoding: d[(d.startIndex + p + 46)..<(d.startIndex + p + 46 + nlen)], as: UTF8.self)
            p += 46 + nlen + elen + clen

            guard local + 30 <= d.count, u32(d, local) == 0x04034b50 else { continue }
            let start = local + 30 + u16(d, local + 26) + u16(d, local + 28)
            guard start + csize <= d.count else { continue }
            let raw = Data(d[(d.startIndex + start)..<(d.startIndex + start + csize)])
            switch method {
            case 0: out.append(Entry(name: name, data: raw))
            case 8:
                if let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data { out.append(Entry(name: name, data: inflated)) }
            default: break
            }
        }
        return out
    }
}

// MARK: - Live state for the player

/// The subtitle currently loaded and the playback clock that drives it.
@Observable
final class SubtitleController {
    private(set) var cues: [SubtitleCue] = []
    private(set) var name = ""
    private(set) var lang = ""
    private(set) var text = ""
    private(set) var offset = 0.0
    private(set) var clockSeen = false

    @ObservationIgnored private var position = 0.0
    @ObservationIgnored private var paused = true
    @ObservationIgnored private var stamp = Date.timeIntervalSinceReferenceDate
    @ObservationIgnored private var weight = 0.0

    var isOn: Bool { !cues.isEmpty }

    func load(text: String, cues: [SubtitleCue], name: String, lang: String, offset: Double = 0) {
        self.text = text
        self.cues = cues
        self.name = name
        self.lang = lang
        self.offset = offset
    }

    func clear() {
        cues = []; name = ""; lang = ""; text = ""; offset = 0
    }

    func resetClock() {
        clockSeen = false
        position = 0
        paused = true
        weight = 0
    }

    func nudge(_ delta: Double) { offset = ((offset + delta) * 10).rounded() / 10 }

    /// Called by the video player or the page. When several videos report at once, the biggest wins.
    func setClock(position: Double, paused: Bool, weight w: Double = 1) {
        let now = Date.timeIntervalSinceReferenceDate
        if w < weight, now - stamp < 1.0 { return }
        self.position = position
        self.paused = paused
        self.stamp = now
        self.weight = w
        if !clockSeen { clockSeen = true }
    }

    /// The reporting players tick several times a second while playing, so silence means paused, stalled
    /// or closed. The clock may coast only this long past the last report, then it holds still.
    private static let maxCoast = 1.0

    /// The line to show now, or nil when the real position is unknown or between lines.
    func cue(at date: Date) -> String? {
        guard !cues.isEmpty, clockSeen else { return nil }
        let coast = paused ? 0 : min(max(0, date.timeIntervalSinceReferenceDate - stamp), Self.maxCoast)
        return SubtitleParser.cue(in: cues, at: position + coast + offset)?.text
    }
}

// MARK: - Remembered choice per title

struct SavedSubtitle: Codable {
    var name: String
    var lang: String
    var text: String
    var offset: Double
    var at: Date
}

enum SubtitleStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("subtitles.json")
    }

    private static func all() -> [String: SavedSubtitle] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: SavedSubtitle].self, from: data)) ?? [:]
    }

    static func key(_ ref: MediaRef, season: Int?, episode: Int?) -> String {
        ref.key + (ref.type == .tv ? ":\(season ?? 0):\(episode ?? 0)" : "")
    }

    static func saved(_ key: String) -> SavedSubtitle? { all()[key] }

    static func save(_ key: String, _ s: SavedSubtitle) {
        var map = all()
        map[key] = s
        // Keep only the 12 most recent.
        for k in map.keys.sorted(by: { map[$0]!.at > map[$1]!.at }).dropFirst(12) { map[k] = nil }
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: url, options: .atomic) }
    }

    static func forget(_ key: String) {
        var map = all()
        map[key] = nil
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: url, options: .atomic) }
    }
}
