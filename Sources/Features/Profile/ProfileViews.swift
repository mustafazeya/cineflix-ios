import SwiftUI

// MARK: - Who's watching

/// Netflix-style profile picker. Shown when signed in but no profile is chosen yet, and from the My Stuff menu.
struct ProfilePickerView: View {
    /// true when opened from My Stuff (can be closed); false when a profile must be chosen first.
    var dismissable = true

    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var managing = false
    @State private var editing: EditTarget?
    @State private var loadingID: String?
    @State private var errorText: String?
    @State private var offerImport: SyncProfile?
    @State private var pinTarget: PinTarget?
    @State private var pinPassed: (target: PinTarget, pin: String)?

    /// `profile` is nil when adding. `pin` is the PIN already confirmed for it, needed to change or delete a PIN-protected profile.
    struct EditTarget: Identifiable { let id = UUID(); let profile: SyncProfile?; var pin: String? = nil }
    struct PinTarget: Identifiable { let id = UUID(); let profile: SyncProfile; let managing: Bool }

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 26, alignment: .top)]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 34) {
                    Text(managing ? "Manage profiles" : "Who's watching?")
                        .font(.system(size: 30, weight: .bold))
                        .padding(.top, 56)

                    LazyVGrid(columns: columns, spacing: 30) {
                        ForEach(sync.profiles) { p in
                            Button { tap(p) } label: { tile(p) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("profile-\(p.name)")
                        }
                        if sync.profiles.count < 5 {
                            Button { editing = EditTarget(profile: nil) } label: { addTile }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("profile-add")
                        }
                    }
                    .padding(.horizontal, 28)

                    Button(managing ? "Done" : "Manage profiles") { withAnimation(.easeOut(duration: 0.2)) { managing.toggle() } }
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.dim, lineWidth: 1.5))
                        .foregroundStyle(Theme.text2)

                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(Theme.accent).multilineTextAlignment(.center).padding(.horizontal, 28) }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)

            if dismissable {
                VStack {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.dim) }
                            .padding(18)
                            .accessibilityLabel("Close")
                    }
                    Spacer()
                }
            }
        }
        .task { _ = try? await sync.loadProfiles() }
        .sheet(item: $editing) { target in
            ProfileEditorView(profile: target.profile, currentPin: target.pin)
        }
        .sheet(item: $pinTarget, onDismiss: afterPin) { target in
            PinPromptView(profile: target.profile, reason: target.managing ? "This profile is protected. Enter its PIN to change it." : nil) { pin in
                pinPassed = (target, pin)
            }
        }
        .alert("Add what is on this phone?", isPresented: Binding(get: { offerImport != nil }, set: { if !$0 { offerImport = nil } })) {
            Button("Add it") { Task { await sync.importGuestData(); finish() } }
            Button("Not now", role: .cancel) { sync.markGuestImportAsked(); finish() }
        } message: {
            Text("This phone already has a list and watch history from before you signed in. Add it to \(offerImport?.name ?? "this profile")?")
        }
    }

    private func tile(_ p: SyncProfile) -> some View {
        VStack(spacing: 12) {
            AvatarView(id: p.avatar, name: p.name, colorHex: p.color, corner: 16)
                .frame(width: 118, height: 118)
                .overlay {
                    if managing {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.55))
                            Image(systemName: "pencil").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                    if loadingID == p.id { ProgressView().controlSize(.large) }
                }
                .overlay(alignment: .bottom) {
                    if p.kids {
                        Text("KIDS")
                            .font(.system(size: 11, weight: .heavy)).tracking(1.2)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.white, in: Capsule())
                            .offset(y: 9)
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
            HStack(spacing: 5) {
                if p.hasPin { Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold)) }
                Text(p.name).lineLimit(1)
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(p.id == sync.activeProfileID ? .white : Theme.text2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(p.name)
        .accessibilityValue([p.kids ? "Kids" : nil, p.hasPin ? "PIN protected" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    private var addTile: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface2)
                Image(systemName: "plus").font(.system(size: 38, weight: .light)).foregroundStyle(Theme.dim)
            }
            .frame(width: 118, height: 118)
            Text("Add profile").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.dim)
        }
    }

    private func tap(_ p: SyncProfile) {
        errorText = nil
        if p.hasPin && (managing || (!p.kids && p.id != sync.activeProfileID)) {
            pinTarget = PinTarget(profile: p, managing: managing)
        } else if managing {
            editing = EditTarget(profile: p)
        } else {
            choose(p)
        }
    }

    /// Runs after the PIN sheet has gone, so the next sheet does not fight its dismissal.
    private func afterPin() {
        guard let passed = pinPassed else { return }
        pinPassed = nil
        if passed.target.managing { editing = EditTarget(profile: passed.target.profile, pin: passed.pin) } else { choose(passed.target.profile) }
    }

    private func choose(_ p: SyncProfile) {
        loadingID = p.id
        Task {
            await sync.select(p)
            loadingID = nil
            if sync.shouldOfferGuestImport { offerImport = p } else { finish() }
        }
    }

    private func finish() {
        offerImport = nil
        dismiss()
    }
}

// MARK: - Edit or add a profile

struct ProfileEditorView: View {
    let profile: SyncProfile?
    /// The PIN of a PIN-protected profile, already confirmed by the picker. Needed to change or remove the PIN and to delete the profile.
    var currentPin: String?

    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var avatar = ""
    @State private var picking = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var confirmDelete = false
    @State private var kids = false
    @State private var maxRating: MaturityRating = .pg
    @State private var pinMode: PinMode = .unchanged
    @State private var newPin = ""
    @State private var repeatPin = ""

    private enum PinMode { case unchanged, set, remove }

    private var hasPin: Bool { profile?.hasPin == true }
    private var pinValid: Bool {
        switch pinMode {
        case .unchanged, .remove: true
        case .set: newPin.count >= 4 && newPin == repeatPin
        }
    }
    private var ratingChoices: [MaturityRating] { maxRating == .r ? MaturityRating.selectable + [.r] : MaturityRating.selectable }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Button { picking = true } label: {
                        AvatarView(id: avatar, name: name.isEmpty ? "?" : name, corner: 22)
                            .frame(width: 150, height: 150)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                                    .frame(width: 38, height: 38).background(.white, in: Circle())
                                    .offset(x: 10, y: 10)
                            }
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 24)
                    .accessibilityLabel("Change avatar")
                    .accessibilityIdentifier("change-avatar")

                    VStack(alignment: .leading, spacing: 8) {
                        Kicker(text: "Name")
                        TextField("Name", text: $name)
                            .font(.system(size: 20, weight: .semibold))
                            .padding(14)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onChange(of: name) { _, v in if v.count > 24 { name = String(v.prefix(24)) } }
                            .accessibilityIdentifier("profile-name")
                    }
                    .padding(.horizontal, 20)

                    kidsSection
                    pinSection

                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(Theme.accent).padding(.horizontal, 20) }

                    if profile != nil, sync.profiles.count > 1 {
                        Button("Delete profile", role: .destructive) { confirmDelete = true }
                            .padding(.top, 10)
                    }
                }
            }
            .background(Theme.bg)
            .navigationTitle(profile == nil ? "Add profile" : "Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { if busy { ProgressView() } else { Text("Save").fontWeight(.semibold) } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !pinValid || busy)
                        .accessibilityIdentifier("profile-save")
                }
            }
            .navigationDestination(isPresented: $picking) { AvatarGridView(selection: $avatar) }
            .confirmationDialog("Delete \(profile?.name ?? "profile")?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete profile", role: .destructive) { Task { await remove() } }
            } message: {
                Text("Its list and watch history will be removed from every device. This cannot be undone.")
            }
        }
        .onAppear {
            guard avatar.isEmpty else { return }
            name = profile?.name ?? ""
            kids = profile?.kids ?? false
            maxRating = MaturityRating(code: profile?.maxRating) ?? .pg
            avatar = profile.flatMap { Avatars.find($0.avatar) != nil ? $0.avatar : nil } ?? Avatars.nextFree(sync.profiles.map(\.avatar))
        }
        .presentationBackground(Theme.bg)
    }

    // MARK: Kids and PIN

    private var kidsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $kids.animation(.easeOut(duration: 0.2))) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Kids profile").font(.system(size: 17, weight: .semibold))
                    Text("Only shows titles rated up to the level you choose.").font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
            }
            .accessibilityIdentifier("kids-toggle")
            if kids {
                Picker("Maximum rating", selection: $maxRating) {
                    ForEach(ratingChoices, id: \.self) { Text($0.code).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("max-rating")
                Text("Titles without a US rating are hidden from kids profiles. Leaving a kids profile asks for its PIN when it has one.")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }

    private var pinSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(hasPin && pinMode != .remove ? "PIN protected" : "PIN", systemImage: hasPin && pinMode != .remove ? "lock.fill" : "lock.open")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if hasPin && pinMode == .unchanged {
                    Button("Change") { pinMode = .set }.accessibilityIdentifier("pin-change")
                    Button("Remove", role: .destructive) { pinMode = .remove }.accessibilityIdentifier("pin-remove")
                } else if hasPin {
                    Button("Cancel") { pinMode = .unchanged; newPin = ""; repeatPin = "" }.accessibilityIdentifier("pin-undo")
                }
            }
            .font(.system(size: 15))
            if pinMode == .remove {
                Text("The PIN is removed when you save.").font(.system(size: 13)).foregroundStyle(Theme.dim)
            } else if hasPin && pinMode == .unchanged {
                Text("Asked when this profile is chosen, or when it is changed or left.").font(.system(size: 13)).foregroundStyle(Theme.dim)
            } else {
                PinField(title: hasPin ? "New PIN (4 to 6 digits)" : "PIN (4 to 6 digits, optional)", text: $newPin, identifier: "pin-new")
                    .onChange(of: newPin) { _, v in if !hasPin { pinMode = v.isEmpty ? .unchanged : .set } }
                if !newPin.isEmpty {
                    PinField(title: "Repeat PIN", text: $repeatPin, identifier: "pin-repeat")
                    if !repeatPin.isEmpty && repeatPin != newPin {
                        Text("The PINs do not match.").font(.system(size: 13)).foregroundStyle(Theme.accent)
                    } else if newPin.count < 4 {
                        Text("A PIN has 4 to 6 digits.").font(.system(size: 13)).foregroundStyle(Theme.dim)
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let n = name.trimmingCharacters(in: .whitespaces)
            if let profile {
                let change: PinChange = switch pinMode {
                case .unchanged: .keep
                case .set: .set(newPin, current: profile.hasPin ? currentPin : nil)
                case .remove: .remove(current: currentPin ?? "")
                }
                try await sync.updateProfile(profile, name: n, avatar: avatar, kids: kids, maxRating: maxRating, pin: change)
            } else {
                try await sync.createProfile(name: n, avatar: avatar, kids: kids, maxRating: maxRating, pin: pinMode == .set ? newPin : nil)
            }
            dismiss()
        } catch { errorText = error.localizedDescription }
    }

    private func remove() async {
        guard let profile else { return }
        do { try await sync.deleteProfile(profile, pin: currentPin); dismiss() } catch { errorText = error.localizedDescription }
    }
}

// MARK: - Avatar grid

struct AvatarGridView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(Avatars.groups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Kicker(text: group)
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(Avatars.all.filter { $0.group == group }) { a in
                                Button { selection = a.id; dismiss() } label: {
                                    AvatarView(id: a.id, name: a.name, corner: 14)
                                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white, lineWidth: selection == a.id ? 3 : 0))
                                        .scaleEffect(selection == a.id ? 1.04 : 1)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("avatar-\(a.id)")
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("Choose an avatar")
        .navigationBarTitleDisplayMode(.inline)
    }
}
