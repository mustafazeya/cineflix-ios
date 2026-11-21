import SwiftUI

/// What plays after the current video: the next episode of a series, or the next file in a MEGA folder.
struct UpNext {
    var label: String
    var name: String?
    var still: URL?
    var request: PlaybackRequest
}

/// Shown over the last 30 seconds of an episode, like Netflix: the next episode with a countdown, Play now, and a way to keep watching the credits.
struct NextEpisodeCard: View {
    let next: UpNext
    /// nil = no countdown (autoplay is off, or the countdown was cancelled and the video has ended).
    let deadline: Date?
    let finished: Bool
    let onPlay: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: next.still) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.15) }
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Next Episode").font(.caption.weight(.bold)).foregroundStyle(Theme.dim).textCase(.uppercase)
                Text(next.label + (next.name.map { "  " + $0 } ?? "")).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let deadline {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Text("Starting in \(max(1, Int(ceil(deadline.timeIntervalSinceNow))))").font(.caption.monospacedDigit()).foregroundStyle(Theme.text2)
                    }
                }
                HStack(spacing: 8) {
                    Button("Play now", action: onPlay).buttonStyle(.glassProminent)
                    Button(finished ? "Close" : "Watch credits", action: onDismiss).buttonStyle(.glass)
                }
                .font(.footnote.weight(.semibold))
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
    }
}
