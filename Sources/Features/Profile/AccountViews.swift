import SwiftUI

// MARK: - Account card (top of My Stuff)

struct AccountCard: View {
    @Environment(SyncService.self) private var sync
    @State private var showSignIn = false
    @State private var showPicker = false
    @State private var showConnect = false
    @State private var confirmSignOut = false

    var body: some View {
        Group {
            if sync.isSignedIn, let p = sync.activeProfile {
                signedIn(p)
            } else {
                guest
            }
        }
        .padding(.horizontal, 16)
        .sheet(isPresented: $showSignIn) { SignInView() }
        .sheet(isPresented: $showConnect) { ConnectTVView() }
        .fullScreenCover(isPresented: $showPicker) { ProfilePickerView() }
        .confirmationDialog("Sign out of \(sync.email ?? "this account")?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await sync.signOut() } }
        } message: {
            Text("Your list and history stay in your account. This phone goes back to guest mode and the synced copy on it is removed.")
        }
    }

    private func signedIn(_ p: SyncProfile) -> some View {
        HStack(spacing: 14) {
            AvatarView(id: p.avatar, name: p.name, colorHex: p.color, corner: 12)
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.system(size: 18, weight: .bold))
                Text(statusLine).font(.system(size: 13)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                Button { showPicker = true } label: { Label("Switch profile", systemImage: "person.2") }
                Button { Task { await sync.syncNow() } } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                Button { showConnect = true } label: { Label("Connect a TV", systemImage: "tv") }
                Divider()
                Button(role: .destructive) { confirmSignOut = true } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 24)).foregroundStyle(Theme.text2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Account menu")
            .accessibilityIdentifier("account-menu")
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var guest: some View {
        Button { showSignIn = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "icloud")
                    .font(.system(size: 22)).foregroundStyle(Theme.text2)
                    .frame(width: 54, height: 54)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Guest").font(.system(size: 18, weight: .bold))
                    Text("Sign in to sync your list across devices").font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.dim)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!sync.serverConfigured)
        .opacity(sync.serverConfigured ? 1 : 0.5)
        .accessibilityIdentifier("guest-card")
    }

    private var statusLine: String {
        if sync.isBusy { return "Syncing" }
        if let e = sync.lastError { return e }
        if sync.pending > 0 { return "Waiting to sync" }
        if let d = sync.lastSync { return "Synced " + d.formatted(.relative(presentation: .named)) }
        return sync.email ?? ""
    }
}

// MARK: - Sign in / create account

struct SignInView: View {
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorText: String?
    @FocusState private var focus: Field?
    private enum Field { case email, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(creating ? "Create your account" : "Sign in").font(.system(size: 30, weight: .heavy))
                        Text("Your list, watch history and profiles follow you to every device. Skip this and the app works as a guest.")
                            .font(.system(size: 15)).foregroundStyle(Theme.text2)
                    }

                    VStack(spacing: 12) {
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress).textContentType(.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .email).submitLabel(.next)
                            .onSubmit { focus = .password }
                            .padding(14).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityIdentifier("signin-email")
                        SecureField(creating ? "Password (8+ characters)" : "Password", text: $password)
                            .textContentType(creating ? .newPassword : .password)
                            .focused($focus, equals: .password).submitLabel(.go)
                            .onSubmit { Task { await submit() } }
                            .padding(14).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityIdentifier("signin-password")
                    }

                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(Theme.accent) }

                    Button { Task { await submit() } } label: {
                        HStack { if busy { ProgressView().tint(.black) }; Text(creating ? "Create account" : "Sign in").font(.system(size: 17, weight: .bold)) }
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.black)
                    }
                    .disabled(!valid || busy).opacity(valid ? 1 : 0.5)
                    .accessibilityIdentifier("signin-submit")

                    Button { withAnimation { creating.toggle(); errorText = nil } } label: {
                        Text(creating ? "Already have an account? Sign in" : "New here? Create an account")
                            .font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(Theme.text2)

                    Button { dismiss() } label: { Text("Continue as guest").font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity) }
                        .foregroundStyle(Theme.dim)
                }
                .padding(24)
            }
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationBackground(Theme.bg)
    }

    private var valid: Bool { email.contains("@") && password.count >= (creating ? 8 : 1) }

    private func submit() async {
        guard valid, !busy else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            if creating { try await sync.signUp(email: email, password: password) }
            else { try await sync.signIn(email: email, password: password) }
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}

// MARK: - Connect a TV

struct ConnectTVView: View {
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var device: String?
    @State private var busy = false
    @State private var done = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("Connect a TV").font(.system(size: 30, weight: .heavy))
                Text("On the TV open Profile, choose Sign in, and type the code shown on screen.")
                    .font(.system(size: 15)).foregroundStyle(Theme.text2)

                TextField("ABCD-1234", text: $code)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .padding(16).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: code) { _, v in
                        let clean = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
                        let formatted = clean.count > 4 ? clean.prefix(4) + "-" + clean.dropFirst(4) : clean
                        if formatted != v { code = String(formatted) }
                        device = nil; errorText = nil
                    }
                    .accessibilityIdentifier("tv-code")

                if let device { Label("Found \(device)", systemImage: "tv").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text2) }
                if done { Label("Connected. The TV is signing in now.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                if let errorText { Text(errorText).font(.footnote).foregroundStyle(Theme.accent) }

                Button { Task { await go() } } label: {
                    HStack { if busy { ProgressView().tint(.black) }; Text(done ? "Done" : device == nil ? "Find TV" : "Connect").font(.system(size: 17, weight: .bold)) }
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.black)
                }
                .disabled(code.count < 9 || busy).opacity(code.count < 9 ? 0.5 : 1)
                .accessibilityIdentifier("tv-go")
                Spacer()
            }
            .padding(24)
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationBackground(Theme.bg)
    }

    private func go() async {
        if done { dismiss(); return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            if device == nil { device = try await sync.lookupTV(code: code) }
            else { try await sync.approveTV(code: code); done = true }
        } catch { errorText = error.localizedDescription }
    }
}

// MARK: - Sync section for Settings

struct SyncSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        Section {
            TextField("https://…workers.dev", text: $s.syncServer)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: {
            Text("Sync (optional)")
        } footer: {
            Text("Address of your sync service. It comes preconfigured, so you normally never touch this.")
        }
    }
}
