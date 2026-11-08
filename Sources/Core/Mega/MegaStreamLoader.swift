import AVFoundation

/// Feeds AVPlayer a MEGA file: ranges are fetched from MEGA's storage, decrypted and handed over as they are asked for,
/// so playback starts at once and seeking works without downloading the whole file.
nonisolated final class MegaStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let download: MegaDownload
    private let queue = DispatchQueue(label: "cineflix.mega.loader")
    private var tasks: [AVAssetResourceLoadingRequest: Task<Void, Never>] = [:]
    private let chunk: Int64 = 1_048_576

    init(_ download: MegaDownload) { self.download = download }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "cineflix-mega://stream/video.\(MegaFormat.isVideo(download.name) ? MegaFormat.ext(download.name) : "mp4")")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func cancelAll() {
        queue.async { self.tasks.values.forEach { $0.cancel() }; self.tasks.removeAll() }
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url?.scheme == "cineflix-mega" else { return false }
        tasks[request] = Task { [weak self] in await self?.serve(request) }
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: request)?.cancel()
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) async {
        if let info = request.contentInformationRequest {
            info.contentType = MegaFormat.uti(download.name)
            info.contentLength = download.size
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else { queue.async { request.finishLoading() }; return }
        var offset = data.currentOffset
        let end = data.requestsAllDataToEndOfResource ? download.size : min(download.size, data.requestedOffset + Int64(data.requestedLength))
        let dl = download
        let piece = chunk
        func fetch(_ from: Int64) -> Task<Data, Error> {
            Task { try await MegaAPI.range(dl, from: from, to: min(end - 1, from + piece - 1)) }
        }
        do {
            var pending: Task<Data, Error>? = offset < end ? fetch(offset) : nil
            while offset < end, let current = pending {
                let bytes = try await current.value
                try Task.checkCancellation()
                let next = offset + Int64(bytes.count)
                pending = next < end ? fetch(next) : nil
                queue.async { data.respond(with: bytes) }
                offset = next
            }
            queue.async { request.finishLoading(); self.tasks[request] = nil }
        } catch is CancellationError {
            // The player moved on (a seek); nothing to finish.
        } catch {
            queue.async { request.finishLoading(with: error); self.tasks[request] = nil }
        }
    }
}
