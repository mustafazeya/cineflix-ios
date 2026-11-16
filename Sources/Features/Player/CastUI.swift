import SwiftUI
import AVKit
import GoogleCast

/// The standard Chromecast button. It hides itself when no Chromecast is on the network and opens the device list when tapped.
struct CastButton: UIViewRepresentable {
    var tint: UIColor = .white

    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 38, height: 38))
        button.tintColor = tint
        return button
    }

    func updateUIView(_ button: GCKUICastButton, context: Context) { button.tintColor = tint }
}

/// The system AirPlay picker (Apple TV, AirPlay speakers and TVs).
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = .systemBlue
        picker.tintColor = .white
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}

/// A round glass button that holds a UIKit control, to match the player's own buttons.
struct PlayerControl<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(width: 38, height: 38)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// Shown instead of the video while it plays on the TV: the phone is the remote.
struct CastRemoteView: View {
    let request: PlaybackRequest
    let cast: CastManager
    let onLocal: () -> Void

    @State private var scrubbing = false
    @State private var scrubTo = 0.0

    var body: some View {
        ZStack {
            Color.black
            if let art = TMDB.image(request.backdropPath ?? request.posterPath, "w780") {
                AsyncImage(url: art) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                    .blur(radius: 28)
                    .opacity(0.35)
                    .clipped()
            }
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "tv.badge.wifi")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.text2)
                Text("Casting to \(cast.deviceName.isEmpty ? "your TV" : cast.deviceName)")
                    .font(.subheadline).foregroundStyle(Theme.dim)
                VStack(spacing: 4) {
                    Text(request.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    if let s = request.subtitle { Text(s).font(.subheadline).foregroundStyle(Theme.dim) }
                }
                .padding(.horizontal, 30)

                if let failure = cast.failure {
                    Text(failure).font(.footnote).foregroundStyle(Theme.dim).multilineTextAlignment(.center).padding(.horizontal, 30)
                }

                VStack(spacing: 6) {
                    Slider(value: Binding(get: { scrubbing ? scrubTo : cast.position }, set: { scrubTo = $0 }),
                           in: 0...max(cast.duration, 1)) { scrubbing = $0; if !$0 { cast.seek(to: scrubTo) } }
                        .tint(.white)
                        .disabled(cast.duration <= 0)
                        .accessibilityLabel("Position")
                    HStack {
                        Text(Self.clock(scrubbing ? scrubTo : cast.position))
                        Spacer()
                        Text(Self.clock(cast.duration))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
                }
                .padding(.horizontal, 28)

                HStack(spacing: 34) {
                    Button { cast.skip(by: -10) } label: { Image(systemName: "gobackward.10").font(.system(size: 30)) }
                        .accessibilityLabel("Back 10 seconds")
                    Button { cast.togglePlayPause() } label: {
                        Group {
                            if cast.isBuffering { ProgressView().tint(.white).controlSize(.large) }
                            else { Image(systemName: cast.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 40)) }
                        }
                        .frame(width: 60, height: 60)
                    }
                    .accessibilityLabel(cast.isPlaying ? "Pause" : "Play")
                    Button { cast.skip(by: 10) } label: { Image(systemName: "goforward.10").font(.system(size: 30)) }
                        .accessibilityLabel("Forward 10 seconds")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(Theme.dim)
                    Slider(value: Binding(get: { Double(cast.volume) }, set: { cast.setVolume(Float($0)) }), in: 0...1).tint(.white)
                        .accessibilityLabel("TV volume")
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(Theme.dim)
                }
                .padding(.horizontal, 40)

                HStack(spacing: 12) {
                    Button("Play on this iPhone", action: onLocal).buttonStyle(.glass)
                    Button("Disconnect", role: .destructive) { cast.disconnect() }.buttonStyle(.glass)
                }
                .padding(.top, 6)
                Spacer()
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
