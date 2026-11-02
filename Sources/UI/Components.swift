import SwiftUI

/// Remote artwork with a neutral placeholder. Image responses are cached by URLCache.
struct Artwork: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Theme.surface
            }
        }
    }
}

/// Fills its frame with artwork at a fixed aspect ratio, cropping as needed.
struct ArtworkBox: View {
    let url: URL?
    let ratio: CGFloat
    var corner: CGFloat = 6

    var body: some View {
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay(Artwork(url: url))
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(.black.opacity(0.72), in: Circle())
    }
}

struct AvailableBadge: View {
    var body: some View {
        Text("AVAILABLE")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Watched check and server availability, shared by all card styles.
struct CardBadges: ViewModifier {
    let ref: MediaRef
    @Environment(Library.self) private var library
    @Environment(CatalogState.self) private var catalog

    func body(content: Content) -> some View {
        let watched = library.isWatched(ref)
        content
            .opacity(watched ? 0.55 : 1)
            .overlay(alignment: .topTrailing) { if watched { WatchedBadge().padding(6) } }
            .overlay(alignment: .topLeading) { if catalog.has(ref) == true { AvailableBadge().padding(6) } }
            .accessibilityElement(children: .ignore)
            .accessibilityValue(watched ? "Watched" : "")
    }
}

extension View {
    func cardBadges(_ ref: MediaRef) -> some View { modifier(CardBadges(ref: ref)) }
}

struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat? = 116

    var body: some View {
        ArtworkBox(url: TMDB.image(item.posterPath, "w342"), ratio: 2 / 3)
            .frame(width: width)
            .overlay {
                if item.posterPath == nil {
                    Text(item.title).font(.footnote.weight(.semibold)).padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .cardBadges(item.ref)
            .accessibilityLabel(item.title)
    }
}

struct LandscapeCard: View {
    let item: MediaItem
    var width: CGFloat = 250

    var body: some View {
        ArtworkBox(url: TMDB.image(item.backdropPath ?? item.posterPath, "w780"), ratio: 16 / 9)
            .frame(width: width)
            .overlay(alignment: .bottomLeading) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .top))
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6))
            }
            .cardBadges(item.ref)
            .accessibilityLabel(item.title)
    }
}

/// Netflix-style ranked card: outlined number beside the poster.
struct Top10Card: View {
    let item: MediaItem
    let rank: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: -18) {
            OutlinedNumber(text: "\(rank)")
                .frame(width: rank == 10 ? 92 : 62, alignment: .trailing)
                .offset(y: 14)
            PosterCard(item: item, width: 108)
        }
        .accessibilityLabel("Number \(rank), \(item.title)")
    }
}

private struct OutlinedNumber: View {
    let text: String
    var body: some View {
        let t = Text(text).font(.system(size: 120, weight: .heavy)).tracking(-8)
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) * .pi / 4
                t.foregroundStyle(Color(white: 0.42)).offset(x: cos(a) * 2, y: sin(a) * 2)
            }
            t.foregroundStyle(Theme.bg)
        }
        .fixedSize()
    }
}

struct ContinueCard: View {
    let progress: WatchProgress
    var width: CGFloat = 250

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkBox(url: TMDB.image(progress.backdropPath ?? progress.stillPath, "w780"), ratio: 16 / 9)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.5), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                }
                .overlay(alignment: .bottom) {
                    if progress.fraction > 0 {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.25))
                                Rectangle().fill(Theme.accent).frame(width: g.size.width * progress.fraction)
                            }
                        }
                        .frame(height: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
            }
        }
        .frame(width: width)
    }

    private var subtitle: String {
        if progress.ref.type == .tv, let s = progress.season, let e = progress.episode {
            return "S\(s) E\(e)" + (progress.subtitle.map { " \u{00B7} \($0)" } ?? "")
        }
        if progress.duration > 0 {
            let left = Int((progress.duration - progress.position) / 60)
            return left > 0 ? "\(left) min left" : "Almost done"
        }
        return "Continue"
    }
}

// MARK: - Rows

enum RowStyle { case poster, landscape, top10 }

struct RowHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.cfRowTitle)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
    }
}

struct MediaRow: View {
    let title: String
    let items: [MediaItem]
    var style: RowStyle = .poster

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeader(title: title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: style == .top10 ? 6 : 10) {
                    ForEach(Array(items.enumerated()), id: \.element.ref) { i, item in
                        NavigationLink(value: Route.title(item.ref)) {
                            switch style {
                            case .poster: PosterCard(item: item)
                            case .landscape: LandscapeCard(item: item)
                            case .top10: Top10Card(item: item, rank: i + 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

struct SkeletonRow: View {
    var style: RowStyle = .poster
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 4).fill(Theme.surface2).frame(width: 150, height: 16).padding(.horizontal, 16)
            HStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.surface)
                        .frame(width: style == .landscape ? 250 : 116, height: style == .landscape ? 141 : 174)
                }
            }
            .padding(.horizontal, 16)
        }
        .opacity(pulse ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(), value: pulse)
        .onAppear { pulse = true }
    }
}

/// A row that loads its own items.
struct LoadingRow: View {
    let title: String
    var style: RowStyle = .poster
    let load: () async throws -> [MediaItem]

    @State private var items: [MediaItem]?

    var body: some View {
        Group {
            if let items {
                if !items.isEmpty {
                    MediaRow(title: title, items: style == .top10 ? Array(items.prefix(10)) : items, style: style)
                }
            } else {
                SkeletonRow(style: style)
            }
        }
        .task {
            guard items == nil else { return }
            let loaded = (try? await load()) ?? []
            items = style == .landscape ? loaded.filter { $0.backdropPath != nil } : loaded
        }
    }
}

struct PosterGrid: View {
    let items: [MediaItem]
    var onAppearIndex: ((Int) -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.element.ref) { i, item in
                NavigationLink(value: Route.title(item.ref)) {
                    PosterCard(item: item, width: nil)
                }
                .buttonStyle(.plain)
                .onAppear { onAppearIndex?(i) }
            }
        }
        .padding(.horizontal, 16)
    }
}
