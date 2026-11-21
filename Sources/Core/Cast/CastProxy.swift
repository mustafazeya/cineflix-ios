import Foundation
import Network

/// A small web server on the iPhone that a Chromecast streams from.
///
/// The Chromecast fetches the video itself, so it cannot read the app's MEGA files (they are encrypted) and many
/// servers refuse its requests (no CORS headers). Serving everything from the phone solves both: MEGA ranges are
/// decrypted on the fly, other streams are passed through with the headers the receiver needs, HLS playlists are
/// rewritten so every segment also comes through here, and subtitles are served as WebVTT.
nonisolated final class CastProxy: @unchecked Sendable {
    static let shared = CastProxy()

    enum Source: Sendable {
        /// `headers` are what the original page sent (Referer, Cookie, ...) for streams that check them; the receiver cannot send them itself.
        case url(URL, headers: [String: String] = [:])
        case mega(MegaDownload)
        case subtitles(String)
    }

    fileprivate let queue = DispatchQueue(label: "cineflix.cast-proxy")
    fileprivate let session: URLSession

    private var listener: NWListener?
    private var port: UInt16 = 0
    private var sources: [String: Source] = [:]
    private var exchanges: [ObjectIdentifier: AnyObject] = [:]
    private let maxSources = 20_000

    private init() {
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = queue
        session = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: operations)
    }

    // MARK: Lifecycle

    private func start() {
        queue.async {
            guard self.listener == nil, let listener = try? NWListener(using: .tcp) else { return }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                if case .ready = state { self?.port = listener?.port?.rawValue ?? 0 }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                let exchange = Exchange(connection: connection, proxy: self)
                self.exchanges[ObjectIdentifier(exchange)] = exchange
                exchange.begin()
            }
            listener.start(queue: self.queue)
            self.listener = listener
        }
    }

    func stop() {
        queue.async {
            self.exchanges.values.forEach { ($0 as? Exchange)?.abort() }
            self.exchanges.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.port = 0
            self.sources.removeAll()
        }
    }

    /// The address the receiver should load for `source`, or nil when the phone has no network address to offer.
    func publish(_ source: Source) async -> URL? {
        start()
        for _ in 0..<30 {
            if queue.sync(execute: { port != 0 }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let host = Self.localIPv4Address() else { return nil }
        return queue.sync {
            guard port != 0 else { return nil }
            return URL(string: "http://\(host):\(port)\(register(source))")
        }
    }

    /// Must run on `queue`. Returns the path the receiver should request.
    fileprivate func register(_ source: Source) -> String {
        if sources.count > maxSources { sources.removeAll() }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        sources[token] = source
        // The extension lets the receiver recognise the stream type from the address.
        let ext: String
        switch source {
        case .url(let url, _): ext = url.pathExtension.lowercased()
        case .mega(let dl): ext = MegaFormat.isVideo(dl.name) ? MegaFormat.ext(dl.name) : "mp4"
        case .subtitles: ext = "vtt"
        }
        return "/p/\(token)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    fileprivate func release(_ exchange: AnyObject) { exchanges[ObjectIdentifier(exchange)] = nil }

    fileprivate func source(forPath path: String) -> Source? {
        let name = path.split(separator: "?").first.map(String.init) ?? path
        guard name.hasPrefix("/p/") else { return nil }
        return sources[name.dropFirst(3).split(separator: ".").first.map(String.init) ?? ""]
    }

    // MARK: Kinds of stream

    /// The MIME type the receiver needs. Addresses without a telling extension are sniffed, because announcing an HLS
    /// playlist as MP4 leaves the TV blank.
    static func mimeType(for source: Source) async -> String {
        switch source {
        case .subtitles: return "text/vtt"
        case .mega(let dl):
            let known = fileType(MegaFormat.ext(dl.name))
            return known.isEmpty ? "video/mp4" : known
        case .url(let url, let headers):
            let path = url.path.lowercased()
            if path.hasSuffix(".m3u8") { return "application/x-mpegURL" }
            if path.hasSuffix(".mpd") { return "application/dash+xml" }
            let known = fileType(url.pathExtension.lowercased())
            if !known.isEmpty { return known }
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            request.timeoutInterval = 15
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { return "video/mp4" }
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if String(decoding: data.prefix(512), as: UTF8.self).contains("#EXTM3U") || header.contains("mpegurl") { return "application/x-mpegURL" }
            if header.hasPrefix("video/") { return header.split(separator: ";").first.map(String.init) ?? "video/mp4" }
            if data.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "video/webm" }
            return "video/mp4"
        }
    }

    private static func fileType(_ ext: String) -> String {
        switch ext {
        case "webm": "video/webm"
        case "mkv": "video/x-matroska"
        case "mp4", "m4v", "mov": "video/mp4"
        case "ts", "m2ts": "video/mp2t"
        default: ""
        }
    }

    /// The receiver only understands WebVTT; the app's subtitles are parsed cues, shifted by the user's sync offset.
    static func webVTT(cues: [SubtitleCue], offset: Double) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return "WEBVTT\n\n" + cues.map { "\(stamp($0.start + offset)) --> \(stamp($0.end + offset))\n\($0.text)\n" }.joined(separator: "\n")
    }

    private static func localIPv4Address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  Int32(interface.ifa_flags) & IFF_UP != 0, Int32(interface.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer)
            if name == "en0" { return ip }
            fallback = fallback ?? ip
        }
        return fallback
    }
}

// MARK: - One request from the receiver

private nonisolated final class Exchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let proxy: CastProxy
    private var task: URLSessionDataTask?
    private var worker: Task<Void, Never>?
    private var source: CastProxy.Source?
    private var requestBuffer = Data()

    private var buffering = false
    private var body = Data()
    private var responseURL: URL?
    private var headSent = false
    private var pendingBytes = 0
    private var suspended = false

    private static let cors = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Access-Control-Allow-Headers": "Range, Content-Type, Origin, Accept",
        "Access-Control-Expose-Headers": "Content-Length, Content-Range, Accept-Ranges, Content-Type"
    ]

    init(connection: NWConnection, proxy: CastProxy) {
        self.connection = connection
        self.proxy = proxy
    }

    func abort() {
        task?.cancel()
        worker?.cancel()
        connection.cancel()
    }

    func begin() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed:
                self.abort()
            case .cancelled:
                self.task?.cancel()
                self.worker?.cancel()
                self.proxy.release(self)
            default:
                break
            }
        }
        connection.start(queue: proxy.queue)
        receiveRequest()
    }

    // MARK: Request

    private func receiveRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, error == nil else { return self.connection.cancel() }
            self.requestBuffer.append(data)
            if let end = self.requestBuffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(String(decoding: self.requestBuffer[..<end.lowerBound], as: UTF8.self))
            } else if self.requestBuffer.count > 32_768 {
                self.finish(status: 431)
            } else {
                self.receiveRequest()
            }
        }
    }

    private func handle(_ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2 else { return finish(status: 400) }
        let method = parts[0].uppercased()
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        if method == "OPTIONS" { return finish(status: 204) }
        guard method == "GET" || method == "HEAD" else { return finish(status: 405) }
        guard let source = proxy.source(forPath: parts[1]) else { return finish(status: 404) }
        self.source = source

        switch source {
        case .subtitles(let text):
            send(status: 200, headers: ["Content-Type": "text/vtt; charset=utf-8"], body: method == "HEAD" ? Data() : Data(text.utf8))
        case .url(let url, let extra):
            var request = URLRequest(url: url)
            request.httpMethod = method
            extra.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            if let range = headers["range"] { request.setValue(range, forHTTPHeaderField: "Range") }
            let task = proxy.session.dataTask(with: request)
            task.delegate = self
            self.task = task
            task.resume()
        case .mega(let download):
            worker = Task { [weak self] in await self?.serveMega(download, method: method, range: headers["range"]) }
        }
    }

    // MARK: MEGA

    /// Range handling for a file whose bytes only exist after decryption.
    private func serveMega(_ dl: MegaDownload, method: String, range: String?) async {
        let size = dl.size
        let type = await CastProxy.mimeType(for: .mega(dl))
        var start: Int64 = 0
        var end = size - 1
        var partial = false
        if let range, range.lowercased().hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
            let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { Int64($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 2 {
                switch (bounds[0], bounds[1]) {
                case (let a?, let b?): start = a; end = min(b, size - 1); partial = true
                case (let a?, nil): start = a; partial = true
                case (nil, let n?): start = max(0, size - n); partial = true
                default: break
                }
            }
        }
        guard start < size, start <= end else {
            return send(status: 416, headers: ["Content-Range": "bytes */\(size)"], body: Data())
        }
        var headers = ["Content-Type": type, "Accept-Ranges": "bytes", "Content-Length": String(end - start + 1)]
        if partial { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
        sendHead(status: partial ? 206 : 200, headers: headers)
        if method == "HEAD" { return close() }

        let piece: Int64 = 1_048_576
        let last = end
        var offset = start
        var pending: Task<Data, Error>? = Task { [offset] in try await MegaAPI.range(dl, from: offset, to: min(last, offset + piece - 1)) }
        while offset <= end, let current = pending {
            guard let bytes = try? await current.value, !bytes.isEmpty else { break }
            let next = offset + Int64(bytes.count)
            pending = next <= end ? Task { try await MegaAPI.range(dl, from: next, to: min(last, next + piece - 1)) } : nil
            if Task.isCancelled { pending?.cancel(); return }
            // Wait until the receiver has taken the piece, so memory stays flat when it reads slowly.
            let sent: Bool = await withCheckedContinuation { continuation in
                connection.send(content: bytes, completion: .contentProcessed { continuation.resume(returning: $0 == nil) })
            }
            guard sent else { pending?.cancel(); return }
            offset = next
        }
        close()
    }

    // MARK: Upstream response (passed through)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return finish(status: 502)
        }
        responseURL = http.url
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let path = (http.url ?? dataTask.originalRequest?.url)?.path.lowercased() ?? ""
        let isPlaylist = path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") || contentType.contains("mpegurl")
        buffering = dataTask.originalRequest?.httpMethod != "HEAD" && isPlaylist

        if !buffering {
            var out: [String: String] = [:]
            for name in ["Content-Type", "Content-Range", "Accept-Ranges"] {
                if let value = http.value(forHTTPHeaderField: name) { out[name] = value }
            }
            if http.value(forHTTPHeaderField: "Content-Encoding") == nil, let length = http.value(forHTTPHeaderField: "Content-Length") { out["Content-Length"] = length }
            sendHead(status: http.statusCode, headers: out)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if buffering {
            body.append(data)
            return
        }
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.pendingBytes -= data.count
            if self.suspended && self.pendingBytes < 512 * 1024 {
                self.suspended = false
                self.task?.resume()
            }
        })
        // The receiver reads slower than the server delivers; pause the download instead of filling memory.
        if pendingBytes > 2 * 1024 * 1024 && !suspended {
            suspended = true
            dataTask.suspend()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil, !headSent { return finish(status: 502) }
        guard buffering, case .url(let original, let headers)? = source else { return close() }
        let text = rewritePlaylist(String(decoding: body, as: UTF8.self), base: responseURL ?? original, headers: headers)
        send(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(text.utf8))
    }

    /// Points every URL in an HLS playlist back at this proxy.
    private func rewritePlaylist(_ text: String, base: URL, headers: [String: String]) -> String {
        let attribute = try? NSRegularExpression(pattern: #"URI="([^"]*)""#)

        func proxied(_ reference: String) -> String? {
            guard let absolute = URL(string: reference, relativeTo: base)?.absoluteURL, absolute.scheme == "http" || absolute.scheme == "https" else { return nil }
            return proxy.register(.url(absolute, headers: headers))
        }

        return text.components(separatedBy: .newlines).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }
            guard trimmed.hasPrefix("#") else { return proxied(trimmed) ?? line }
            guard let attribute else { return line }
            var result = line
            for match in attribute.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let whole = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: result),
                      let replacement = proxied(String(result[inner])) else { continue }
                result.replaceSubrange(whole, with: "URI=\"\(replacement)\"")
            }
            return result
        }.joined(separator: "\n")
    }

    // MARK: Writing

    private func sendHead(status: Int, headers: [String: String]) {
        guard !headSent else { return }
        headSent = true
        var lines = ["HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)"]
        for (name, value) in headers.merging(Self.cors, uniquingKeysWith: { current, _ in current }) { lines.append("\(name): \(value)") }
        lines.append("Connection: close")
        connection.send(content: Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8), completion: .contentProcessed { _ in })
    }

    private func send(status: Int, headers: [String: String], body: Data) {
        var headers = headers
        headers["Content-Length"] = String(body.count)
        sendHead(status: status, headers: headers)
        connection.send(content: body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func finish(status: Int) { send(status: status, headers: ["Content-Length": "0"], body: Data()) }

    private func close() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}
