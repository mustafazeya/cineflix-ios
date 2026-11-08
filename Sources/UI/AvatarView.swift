import SwiftUI

/// A profile picture: the shared artwork on its gradient, or the profile colour and initial when the avatar is unknown.
struct AvatarView: View {
    let id: String?
    let name: String
    var colorHex: String?
    var corner: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                if let avatar = Avatars.find(id) {
                    LinearGradient(colors: [Color(hex: avatar.top), Color(hex: avatar.bottom)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image("avatar-\(avatar.id)")
                        .resizable()
                        .scaledToFit()
                } else {
                    Color(hex: UInt32((colorHex ?? "#3a3a3a").dropFirst(), radix: 16) ?? 0x3A3A3A)
                    Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                        .font(.system(size: size * 0.46, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(name)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
