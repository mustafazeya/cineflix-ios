import Foundation
import CommonCrypto

// MEGA public links, read on the phone itself: nothing goes to any CineFlix server and the key never leaves the device.
// Folder and file links are listed through MEGA's public API, names and keys are decrypted with AES, and file data is AES-CTR.

nonisolated struct MegaLink: Hashable, Sendable {
    enum Kind: Sendable { case folder, file }
    var kind: Kind
    var id: String
    var key: Data
    /// A folder link may point inside the folder, at a subfolder or at one file.
    var sub: String?
    var subIsFile = false

    var isSingleFile: Bool { kind == .file || (sub != nil && subIsFile) }

    /// One spelling for every link, whatever was pasted.
    var canonical: String {
        let base = kind == .folder ? "https://mega.nz/folder/" : "https://mega.nz/file/"
        var s = base + id + "#" + Base64URL.encode(key)
        if let sub { s += (subIsFile ? "/file/" : "/folder/") + sub }
        return s
    }

    private static let id = "[A-Za-z0-9_-]{8}"
    private static let key = "[A-Za-z0-9_-]{22,43}"
    private static let host = "mega(?:\\.co)?\\.(?:nz|io)"

    static func parse(_ text: String) -> MegaLink? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func groups(_ pattern: String) -> [String?]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
            return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: t).map { String(t[$0]) } }
        }
        if let g = groups("\(host)/folder/(\(id))#(\(key))(?:/(folder|file)/(\(id)))?") {
            return make(.folder, g[0], g[1], sub: g[3], subIsFile: g[2]?.lowercased() == "file")
        }
        if let g = groups("\(host)/#F!(\(id))!(\(key))(?:[!?/](\(id)))?") { return make(.folder, g[0], g[1], sub: g[2], subIsFile: false) }
        if let g = groups("\(host)/file/(\(id))#(\(key))") { return make(.file, g[0], g[1], sub: nil, subIsFile: false) }
        if let g = groups("\(host)/#!(\(id))!(\(key))") { return make(.file, g[0], g[1], sub: nil, subIsFile: false) }
        return nil
    }

    private static func make(_ kind: Kind, _ id: String?, _ key: String?, sub: String?, subIsFile: Bool) -> MegaLink? {
        guard let id, let key, let k = Base64URL.decode(key) else { return nil }
        guard (kind == .folder && k.count == 16) || (kind == .file && k.count == 32) else { return nil }
        return MegaLink(kind: kind, id: id, key: k, sub: sub, subIsFile: subIsFile)
    }
}

nonisolated enum Base64URL {
    static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: ",", with: "")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

nonisolated struct MegaNode: Identifiable, Hashable, Sendable {
    let id: String
    let parent: String
    let isDir: Bool
    let name: String
    let size: Int64
    let key: Data

    /// A file worth listing: a known video type, or a large file with an unfamiliar extension (some folders have none).
    var isVideo: Bool { MegaFormat.isCandidate(name, size: size) }
}

nonisolated struct MegaFolder: Sendable {
    let rootName: String
    let nodes: [MegaNode]
    let single: Bool

    func node(_ id: String) -> MegaNode? { nodes.first { $0.id == id } }

    /// Folders first, then names in natural order (episode 2 before episode 10).
    func children(of parent: String) -> [MegaNode] {
        nodes.filter { $0.parent == parent }.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func videoCount(in parent: String) -> Int {
        children(of: parent).reduce(0) { $0 + ($1.isDir ? videoCount(in: $1.id) : ($1.isVideo ? 1 : 0)) }
    }

    /// For an empty listing: what the folder does hold, e.g. "12 files: .rar x9, .jpg x3".
    var inventory: String {
        let files = nodes.filter { !$0.isDir }
        guard !files.isEmpty else { return "The folder has no files." }
        var counts: [String: Int] = [:]
        files.forEach { counts[MegaFormat.ext($0.name).isEmpty ? "no extension" : "." + MegaFormat.ext($0.name), default: 0] += 1 }
        let top = counts.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
        return "The folder has \(files.count) file\(files.count == 1 ? "" : "s"): \(top)."
    }

    /// Every video in the tree, in path order. Used when the folder structure can't be followed.
    var allVideos: [MegaNode] {
        nodes.filter { !$0.isDir && $0.isVideo }.sorted { lhs, rhs in
            let a = path(to: lhs.parent).joined(separator: "/"), b = path(to: rhs.parent).joined(separator: "/")
            return a == b ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// What a folder page lists: videos, and folders that hold at least one video.
    func listing(of parent: String) -> [MegaNode] {
        children(of: parent).filter { $0.isDir ? videoCount(in: $0.id) > 0 : $0.isVideo }
    }

    func path(to id: String) -> [String] {
        var names: [String] = []
        var cur = node(id)
        var guardCount = 0
        while let n = cur, guardCount < 30 { names.insert(n.name, at: 0); cur = node(n.parent); guardCount += 1 }
        return names
    }
}

nonisolated struct MegaDownload: Sendable {
    let url: URL
    let size: Int64
    let aesKey: Data
    let nonce: Data
    let name: String
}

nonisolated enum MegaFormat {
    static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts", "mpg", "mpeg", "wmv", "flv", "3gp", "ogv"]
    static func isVideo(_ name: String) -> Bool { videoExtensions.contains(ext(name)) }

    /// Things that are certainly not videos, so a big file of another kind is not offered as one.
    static let otherExtensions: Set<String> = ["txt", "nfo", "jpg", "jpeg", "png", "gif", "webp", "bmp", "srt", "sub", "idx", "ass", "ssa", "vtt",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "zip", "rar", "7z", "tar", "gz", "iso", "exe", "dmg", "apk", "lnk", "url", "html", "htm",
        "db", "ini", "sfv", "md5", "nzb", "torrent", "mp3", "flac", "wav", "aac", "m4a", "ogg", "epub", "mobi", "cbz", "cbr", "json", "xml", "log"]
    static let bigFile: Int64 = 30 * 1_048_576

    static func isCandidate(_ name: String, size: Int64) -> Bool {
        if isVideo(name) { return true }
        return !otherExtensions.contains(ext(name)) && size >= bigFile
    }

    /// iPhone's player reads MP4 and QuickTime containers; the TV plays more. An unfamiliar extension gets a try as MP4.
    static func playsOnPhone(_ name: String) -> Bool { ["mp4", "m4v", "mov"].contains(ext(name)) || !isVideo(name) }
    static func uti(_ name: String) -> String { ext(name) == "mov" ? "com.apple.quicktime-movie" : "public.mpeg-4" }
}

nonisolated enum MegaError: LocalizedError {
    case message(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): m
        case .unsupported(let ext): "iPhone can't play .\(ext) files. They play on your TV, or convert them to MP4."
        }
    }
}

// MARK: - Crypto

nonisolated enum MegaCrypto {
    private static func cbc(_ key: Data, _ data: Data, iv: Data = Data(count: 16), ecb: Bool = false) -> Data? {
        guard key.count == 16, data.count % 16 == 0, !data.isEmpty else { return nil }
        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(ecb ? kCCOptionECBMode : 0),
                                k.baseAddress, 16, v.baseAddress, d.baseAddress, data.count, o.baseAddress, data.count, &moved)
                    }
                }
            }
        }
        return status == kCCSuccess ? out : nil
    }

    static func ecbDecrypt(_ key: Data, _ data: Data) -> Data? { cbc(key, data, ecb: true) }
    static func cbcZeroDecrypt(_ key: Data, _ data: Data) -> Data? { cbc(key, data) }

    /// A file key is 32 bytes: the AES key is the first half xor the second half, and the CTR nonce is bytes 16..23.
    static func fileKeyParts(_ key: Data) -> (aes: Data, nonce: Data)? {
        guard key.count == 32 else { return nil }
        let k = [UInt8](key)
        return (Data((0..<16).map { k[$0] ^ k[$0 + 16] }), Data(k[16..<24]))
    }

    /// Decrypts bytes that start at `offset` in the file (AES-CTR, 8-byte nonce and a 64-bit block counter).
    static func ctr(aes: Data, nonce: Data, offset: Int64, data: Data) -> Data? {
        let first = offset - offset % 16
        var iv = [UInt8](repeating: 0, count: 16)
        iv.replaceSubrange(0..<8, with: [UInt8](nonce))
        var block = UInt64(first / 16)
        for i in stride(from: 15, through: 8, by: -1) { iv[i] = UInt8(block & 0xff); block >>= 8 }
        let lead = Int(offset - first)
        var input = Data(count: lead)
        input.append(data)
        var out = Data(count: input.count)
        var cryptor: CCCryptorRef?
        let created = aes.withUnsafeBytes { k in
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                    iv, k.baseAddress, 16, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        }
        guard created == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in CCCryptorUpdate(cryptor, i.baseAddress, input.count, o.baseAddress, input.count, &moved) }
        }
        guard status == kCCSuccess else { return nil }
        return out.suffix(from: out.startIndex + lead)
    }
}

// MARK: - API

nonisolated enum MegaAPI {
    /// UI tests point this at a local stand-in with -cf.megaApi.
    nonisolated(unsafe) static var endpoint = UserDefaults.standard.string(forKey: "cf.megaApi") ?? "https://g.api.mega.co.nz/cs"
    private static let errors: [Int: String] = [
        -2: "This MEGA link is not valid.", -9: "This MEGA link was not found. It may have been removed.",
        -11: "This MEGA link is not allowed to be opened.", -13: "This MEGA link is not complete.", -14: "The MEGA link key is wrong.",
        -16: "MEGA has blocked this link.", -17: "MEGA says the transfer limit for this link is used up. Try again later.",
        -18: "This MEGA link is temporarily unavailable. Try again later."
    ]

    private static func call(_ command: [String: Any], folder: String?, attempt: Int = 0) async throws -> [String: Any] {
        var comps = URLComponents(string: endpoint)!
        comps.queryItems = [URLQueryItem(name: "id", value: String(Int.random(in: 0..<Int(Int32.max))))] + (folder.map { [URLQueryItem(name: "n", value: $0)] } ?? [])
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: [command])
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: req) }
        catch { throw MegaError.message("Could not reach MEGA. Check the internet connection.") }
        let json = try? JSONSerialization.jsonObject(with: data)
        let first = (json as? [Any])?.first ?? json
        if let code = first as? Int {
            if code == -3, attempt < 4 {
                try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                return try await call(command, folder: folder, attempt: attempt + 1)
            }
            throw MegaError.message(errors[code] ?? "MEGA returned error \(code).")
        }
        guard let dict = first as? [String: Any] else { throw MegaError.message("MEGA gave an answer this app doesn't understand.") }
        return dict
    }

    private static func attrs(_ b64: String?, key: Data) -> [String: Any]? {
        guard let b64, var data = Base64URL.decode(b64) else { return nil }
        if data.count % 16 != 0 { data.append(Data(count: 16 - data.count % 16)) }
        guard let plain = MegaCrypto.cbcZeroDecrypt(key, data) else { return nil }
        var bytes = [UInt8](plain)
        while bytes.last == 0 { bytes.removeLast() }
        guard let text = String(bytes: bytes, encoding: .utf8), text.hasPrefix("MEGA{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text.dropFirst(4).utf8)) as? [String: Any] else { return nil }
        return obj
    }

    private static func node(from raw: [String: Any], folderKey: Data) -> MegaNode? {
        guard let h = raw["h"] as? String else { return nil }
        let isDir = (raw["t"] as? Int) == 1
        let want = isDir ? 16 : 32
        for part in String(describing: raw["k"] ?? "").split(separator: "/") {
            let pieces = part.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2, let enc = Base64URL.decode(String(pieces[1])), enc.count >= want,
                  let key = MegaCrypto.ecbDecrypt(folderKey, enc.prefix(want)) else { continue }
            let attrKey = isDir ? key : MegaCrypto.fileKeyParts(key)?.aes
            guard let attrKey, let a = attrs(raw["a"] as? String, key: attrKey) else { continue }
            return MegaNode(id: h, parent: raw["p"] as? String ?? "", isDir: isDir, name: a["n"] as? String ?? "",
                            size: (raw["s"] as? NSNumber)?.int64Value ?? 0, key: key)
        }
        return nil
    }

    static func open(_ link: MegaLink) async throws -> MegaFolder {
        if link.kind == .file {
            let r = try await call(["a": "g", "p": link.id, "ssl": 1], folder: nil)
            guard let parts = MegaCrypto.fileKeyParts(link.key), let a = attrs(r["at"] as? String, key: parts.aes) else { throw MegaError.message(errors[-14]!) }
            let name = a["n"] as? String ?? "Video"
            let node = MegaNode(id: link.id, parent: "", isDir: false, name: name, size: (r["s"] as? NSNumber)?.int64Value ?? 0, key: link.key)
            return MegaFolder(rootName: name, nodes: [node], single: true)
        }
        let r = try await call(["a": "f", "c": 1, "r": 1], folder: link.id)
        let raws = (r["f"] as? [[String: Any]]) ?? []
        let all = raws.compactMap { node(from: $0, folderKey: link.key) }
        guard !all.isEmpty else { throw MegaError.message("This folder is empty, or the link key is wrong.") }
        let root = all.first { $0.id == link.id }
        let inside = all.filter { $0.id != link.id }
        // Whatever sits at the top of the tree is the top level, however MEGA happens to name the parent.
        let ids = Set(inside.map(\.id))
        var nodes = inside.map { ids.contains($0.parent) ? $0 : MegaNode(id: $0.id, parent: "", isDir: $0.isDir, name: $0.name, size: $0.size, key: $0.key) }
        var rootName = root?.name ?? "MEGA folder"
        // A lone wrapper folder at the top is skipped: its contents are the top level.
        let tops = nodes.filter { $0.parent.isEmpty }
        if tops.count == 1, let wrapper = tops.first, wrapper.isDir {
            if root == nil { rootName = wrapper.name }
            nodes = nodes.filter { $0.id != wrapper.id }.map {
                $0.parent == wrapper.id ? MegaNode(id: $0.id, parent: "", isDir: $0.isDir, name: $0.name, size: $0.size, key: $0.key) : $0
            }
        }
        return MegaFolder(rootName: rootName, nodes: nodes, single: false)
    }

    static func download(_ link: MegaLink, _ node: MegaNode) async throws -> MegaDownload {
        let cmd: [String: Any] = link.kind == .file ? ["a": "g", "g": 1, "p": link.id, "ssl": 1] : ["a": "g", "g": 1, "n": node.id, "ssl": 1]
        let r = try await call(cmd, folder: link.kind == .file ? nil : link.id)
        let raw = (r["g"] as? String) ?? (r["g"] as? [String])?.first
        guard var s = raw else { throw MegaError.message("MEGA did not give a download address for this file.") }
        if s.hasPrefix("http://"), let host = URL(string: s)?.host, host.hasSuffix(".mega.co.nz") || host.hasSuffix(".mega.nz") { s = "https://" + s.dropFirst(7) }
        guard let url = URL(string: s), let parts = MegaCrypto.fileKeyParts(node.key) else { throw MegaError.message("MEGA gave an unusable download address.") }
        return MegaDownload(url: url, size: (r["s"] as? NSNumber)?.int64Value ?? node.size, aesKey: parts.aes, nonce: parts.nonce, name: node.name)
    }

    /// The decrypted bytes first...last (inclusive).
    static func range(_ dl: MegaDownload, from start: Int64, to end: Int64) async throws -> Data {
        let first = start - start % 16
        guard let url = URL(string: dl.url.absoluteString + "/\(first)-\(end)") else { throw MegaError.message("Bad download address.") }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 || (resp as? HTTPURLResponse)?.statusCode == 206 else {
            throw MegaError.message("MEGA stopped sending this video. It may have reached its transfer limit; try again later.")
        }
        guard let plain = MegaCrypto.ctr(aes: dl.aesKey, nonce: dl.nonce, offset: first, data: data) else { throw MegaError.message("Could not decrypt this video.") }
        return plain.suffix(from: plain.startIndex + Int(start - first))
    }
}

/// Keeps opened folders for the session, so browsing and Next are instant.
actor MegaStore {
    static let shared = MegaStore()
    private var cache: [String: MegaFolder] = [:]

    func folder(for link: MegaLink) async throws -> MegaFolder {
        if let c = cache[link.canonical] { return c }
        let f = try await MegaAPI.open(link)
        cache[link.canonical] = f
        return f
    }

    func forget(_ link: MegaLink) { cache[link.canonical] = nil }
}
