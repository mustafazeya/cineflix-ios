import SwiftUI

/// A PIN field: digits only, up to six, numeric keypad, hidden as it is typed.
struct PinField: View {
    let title: String
    @Binding var text: String
    var identifier: String

    var body: some View {
        SecureField(title, text: $text)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(.system(size: 20, weight: .semibold, design: .monospaced))
            .padding(14)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: text) { _, v in
                let clean = String(v.filter(\.isNumber).prefix(6))
                if clean != v { text = clean }
            }
            .accessibilityIdentifier(identifier)
    }
}

/// Asks for a profile's PIN and checks it with the server. Wrong PINs and the server's attempt limit are shown as written.
struct PinPromptView: View {
    let profile: SyncProfile
    var reason: String?
    /// Called with the PIN once the server accepted it, just before the sheet closes.
    let onVerified: (String) -> Void

    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                AvatarView(id: profile.avatar, name: profile.name, colorHex: profile.color, corner: 16)
                    .frame(width: 84, height: 84)
                VStack(spacing: 6) {
                    Text("Enter PIN for \(profile.name)").font(.system(size: 20, weight: .bold))
                    if let reason { Text(reason).font(.system(size: 14)).foregroundStyle(Theme.text2).multilineTextAlignment(.center) }
                }
                PinField(title: "PIN", text: $pin, identifier: "pin-field")
                    .multilineTextAlignment(.center)
                    .onSubmit { Task { await submit() } }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(Theme.accent).multilineTextAlignment(.center)
                        .accessibilityIdentifier("pin-error")
                }
                Button { Task { await submit() } } label: {
                    HStack { if busy { ProgressView().tint(.black) }; Text("Unlock").font(.system(size: 17, weight: .bold)) }
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.black)
                }
                .disabled(pin.count < 4 || busy).opacity(pin.count < 4 ? 0.5 : 1)
                .accessibilityIdentifier("pin-submit")
                Spacer(minLength: 0)
            }
            .padding(24)
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("pin-cancel") } }
        }
        .presentationBackground(Theme.bg)
        .presentationDetents([.medium, .large])
    }

    private func submit() async {
        guard pin.count >= 4, !busy else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            try await sync.verifyPin(profile, pin)
            onVerified(pin)
            dismiss()
        } catch {
            pin = ""
            errorText = error.localizedDescription
        }
    }
}

/// Shows the PIN prompt for `request` and runs its action once the PIN is accepted and the sheet is gone.
struct PinRequestModifier: ViewModifier {
    @Environment(SyncService.self) private var sync
    @State private var verified: SyncService.PinRequest?

    func body(content: Content) -> some View {
        @Bindable var sync = sync
        content
            .sheet(item: $sync.pinRequest, onDismiss: {
                if let r = verified { verified = nil; r.action() }
            }) { request in
                PinPromptView(profile: request.profile, reason: request.reason) { _ in verified = request }
            }
    }
}

extension View {
    /// Handles `SyncService.guardLeaving` for everything below this view.
    func pinGate() -> some View { modifier(PinRequestModifier()) }
}
