import Foundation
import GoogleCast
import Observation
import UIKit

/// Chromecast, with the same flow as Netflix: connect a TV with the Cast button, and what you play goes to the TV while the
/// phone becomes its remote. The TV loads the video from the phone's own address (see `CastProxy`).
@Observable
final class CastManager: NSObject {
    static let shared = CastManager()

    struct Media {
        var source: CastProxy.Source
        var title: String
        var subtitle: String?
        var artwork: URL?
    }

    private(set) var hasSession = false
    private(set) var hasDevices = false
    private(set) var deviceName = ""
    /// True from the moment a video is sent to the TV until it ends or is stopped.
    private(set) var isCasting = false
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var volume: Float = 0.5
    var failure: String?

    /// Set by whoever is showing the remote; called when the TV finished the video.
    @ObservationIgnored var onFinished: ((_ duration: Double) -> Void)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastMedia: Media?
    @ObservationIgnored private var lastCaptions: String?
    @ObservationIgnored private var attached: GCKRemoteMediaClient?

    private var remoteClient: GCKRemoteMediaClient? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }

    private override init() { super.init() }

    /// Call once at launch. Safe to call again.
    func configure() {
        // UI tests pass -cf.noCast: looking for TVs raises the system's local network prompt, which would cover the screen.
        guard !GCKCastContext.isSharedInstanceInitialized(), !UserDefaults.standard.bool(forKey: "cf.noCast") else { return }
        let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID))
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        options.disableAnalyticsLogging = true
        // Look for TVs from the start, so the Cast button only appears when there is one to connect to.
        options.startDiscoveryAfterFirstTapOnCastButton = false
        GCKCastContext.setSharedInstanceWith(options)
        let discovery = GCKCastContext.sharedInstance().discoveryManager
        discovery.add(self)
        hasDevices = discovery.deviceCount > 0
        let sessions = GCKCastContext.sharedInstance().sessionManager
        sessions.add(self)
        if let session = sessions.currentCastSession { adopt(session) }
    }

    // MARK: Playing on the TV

    /// Sends a video to the TV, starting at `resume` seconds. `captions` is WebVTT text, if subtitles are loaded.
    func load(_ media: Media, resume: Double, captions: String?) async {
        guard let client = remoteClient else { failure = "Connect to a Chromecast first."; return }
        failure = nil
        lastMedia = media
        lastCaptions = captions
        isCasting = true
        position = resume
        UIApplication.shared.isIdleTimerDisabled = true
        startTicker()

        guard let url = await CastProxy.shared.publish(media.source) else {
            return fail("Couldn't find this iPhone's Wi-Fi address. Connect to the same Wi-Fi as the TV.")
        }
        let type = await CastProxy.mimeType(for: media.source)

        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(media.title, forKey: kGCKMetadataKeyTitle)
        if let line = media.subtitle { metadata.setString(line, forKey: kGCKMetadataKeySubtitle) }
        if let art = media.artwork { metadata.addImage(GCKImage(url: art, width: 780, height: 439)) }

        let info = GCKMediaInformationBuilder(contentURL: url)
        // Lets the receiver tell live from on-demand streams itself.
        info.streamType = .unknown
        info.contentType = type
        info.metadata = metadata

        var active: [NSNumber] = []
        if let captions, !captions.isEmpty, let vtt = await CastProxy.shared.publish(.subtitles(captions)),
           let track = GCKMediaTrack(identifier: 1, contentIdentifier: vtt.absoluteString, contentType: "text/vtt", type: .text,
                                     textSubtype: .subtitles, name: "Subtitles", languageCode: "en", customData: nil) {
            info.mediaTracks = [track]
            active = [1]
        }

        let options = GCKMediaLoadOptions()
        options.autoplay = true
        options.playPosition = max(0, resume)
        options.activeTrackIDs = active.isEmpty ? nil : active
        client.loadMedia(info.build(), with: options).delegate = self
    }

    /// New subtitles while casting: the same video again, at the same place.
    func updateCaptions(_ captions: String?) async {
        guard isCasting, let media = lastMedia, captions != lastCaptions else { return }
        await load(media, resume: position, captions: captions)
    }

    /// Stops the video on the TV; the connection stays, so the next title can go straight to it.
    func stopPlayback() {
        remoteClient?.stop()
        ended()
    }

    func disconnect() {
        ended()
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    // MARK: Remote control

    func togglePlayPause() {
        guard let client = remoteClient else { return }
        if isPlaying { client.pause() } else { client.play() }
    }

    func seek(to seconds: Double) {
        let options = GCKMediaSeekOptions()
        options.interval = max(0, seconds)
        remoteClient?.seek(with: options)
        position = options.interval
    }

    func skip(by seconds: Double) {
        let target = position + seconds
        seek(to: duration > 0 ? min(target, duration - 1) : target)
    }

    func setVolume(_ value: Float) {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.setDeviceVolume(min(max(value, 0), 1))
        volume = value
    }

    // MARK: State

    private func adopt(_ session: GCKCastSession) {
        hasSession = true
        deviceName = session.device.friendlyName ?? "Chromecast"
        attached?.remove(self)
        attached = session.remoteMediaClient
        attached?.add(self)
    }

    private func ended() {
        isCasting = false
        isPlaying = false
        isBuffering = false
        duration = 0
        ticker?.cancel()
        ticker = nil
        lastMedia = nil
        lastCaptions = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func fail(_ message: String) {
        failure = message
        remoteClient?.stop()
        ended()
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.refresh()
            }
        }
    }

    private func refresh() {
        guard let client = remoteClient else { return }
        let at = client.approximateStreamPosition()
        if at.isFinite { position = at }
        if let status = client.mediaStatus {
            let length = status.mediaInformation?.streamDuration ?? 0
            duration = length.isFinite ? length : 0
            isPlaying = status.playerState == .playing
            isBuffering = status.playerState == .buffering || status.playerState == .loading
        }
        if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession { volume = session.currentDeviceVolume }
    }
}

// MARK: - Cast SDK callbacks (always on the main thread)

extension CastManager: GCKSessionManagerListener {
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        nonisolated(unsafe) let session = session
        MainActor.assumeIsolated { adopt(session) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        nonisolated(unsafe) let session = session
        MainActor.assumeIsolated { adopt(session) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: (any Error)?) {
        MainActor.assumeIsolated {
            attached?.remove(self)
            attached = nil
            hasSession = false
            deviceName = ""
            ended()
        }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: any Error) {
        MainActor.assumeIsolated { failure = "Couldn't connect to the Chromecast." }
    }
}

extension CastManager: GCKDiscoveryManagerListener {
    nonisolated func didUpdateDeviceList() {
        MainActor.assumeIsolated { hasDevices = GCKCastContext.sharedInstance().discoveryManager.deviceCount > 0 }
    }
}

extension CastManager: GCKRequestDelegate {
    nonisolated func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        MainActor.assumeIsolated {
            fail("The TV couldn't load this video. Check that the TV and iPhone are on the same Wi-Fi, then try again.")
        }
    }
}

extension CastManager: GCKRemoteMediaClientListener {
    nonisolated func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        nonisolated(unsafe) let mediaStatus = mediaStatus
        MainActor.assumeIsolated {
            guard isCasting, let status = mediaStatus, status.playerState == .idle else { return }
            switch status.idleReason {
            case .error:
                fail("The TV couldn't play this video. Its format may not be supported by Chromecast.")
            case .finished:
                let finish = onFinished
                let length = duration
                ended()
                finish?(length)
            default:
                break
            }
        }
    }
}
