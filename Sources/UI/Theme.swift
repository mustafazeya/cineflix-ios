import SwiftUI

enum Theme {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.043)
    static let surface = Color(white: 0.086)
    static let surface2 = Color(white: 0.133)
    static let text2 = Color(white: 0.77)
    static let dim = Color(white: 0.54)
    static let accent = Color(red: 1, green: 0.231, blue: 0.361)
}

extension Font {
    static let cfLargeTitle = Font.system(size: 34, weight: .heavy).width(.standard)
    static let cfRowTitle = Font.system(size: 19, weight: .semibold)
    static let cfLabel = Font.system(size: 12, weight: .bold)
}

/// Small uppercase grey label, used for kickers and section hints.
struct Kicker: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.cfLabel)
            .tracking(1.6)
            .foregroundStyle(Theme.text2)
    }
}

/// Rating, then parts separated by dots.
struct MetaLine: View {
    var rating: String?
    var parts: [String]
    var cert: String?

    var body: some View {
        HStack(spacing: 8) {
            if let rating {
                Label(rating, systemImage: "star.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
                    .fontWeight(.semibold)
                    .imageScale(.small)
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                if i > 0 || rating != nil { Circle().fill(Theme.dim).frame(width: 3, height: 3) }
                Text(p)
            }
            if let cert {
                Text(cert)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.text2.opacity(0.6), lineWidth: 1))
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Theme.text2)
        .lineLimit(1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Icon over a caption, for the action row under the Play button.
struct ActionButton: View {
    let title: String
    let systemImage: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .regular))
                    .frame(height: 24)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(active ? .white : Theme.text2)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: active)
    }
}

struct Chip: View {
    let title: String
    var active = false
    var showsMenu = true

    var body: some View {
        HStack(spacing: 5) {
            Text(title).lineLimit(1)
            if showsMenu { Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
        }
        .font(.system(size: 14, weight: active ? .semibold : .medium))
        .foregroundStyle(active ? .black : .white)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(active ? AnyShapeStyle(.white) : AnyShapeStyle(Color.white.opacity(0.12)), in: Capsule())
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    var systemImage = "film.stack"

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .foregroundStyle(Theme.text2)
            .padding(.top, 60)
    }
}
