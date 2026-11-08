import SwiftUI

/// My Videos: links saved by hand. They sync with the profile and play in the normal player.
struct VideosSection: View {
    @Environment(Library.self) private var library
    @Environment(PlayerPresenter.self) private var presenter
    @State private var editing: EditTarget?
    @State private var deleting: SavedVideo?
    @State private var opening: String?
    @State private var errorText: String?

    struct EditTarget: Identifiable { let id = UUID(); let video: SavedVideo? }


    @ViewBuilder private func rowButton(_ v: SavedVideo) -> some View {
        if v.isMega, let link = MegaLink.parse(v.url), !link.isSingleFile {
            NavigationLink(value: Route.mega(videoID: v.id, folder: link.sub)) { rowLabel(v) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("video-\(v.name)")
        } else {
            Button { play(v) } label: { rowLabel(v) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("video-\(v.name)")
        }
    }

    private func rowLabel(_ v: SavedVideo) -> some View {
        HStack(spacing: 14) {
            Image(systemName: v.isMega ? "folder.fill" : "play.fill")
                .font(.system(size: 16))
                .foregroundStyle(v.isMega ? Color(red: 0.94, green: 0.71, blue: 0.16) : Theme.text2)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(v.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(v.isMega ? megaLabel(v) : v.host).font(.system(size: 13)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            if opening == v.id { ProgressView() }
            else if v.isMega {
                Text("MEGA").font(.system(size: 10, weight: .bold)).tracking(1.2)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .contentShape(Rectangle())
    }

    private func megaLabel(_ v: SavedVideo) -> String {
        MegaLink.parse(v.url).map { $0.isSingleFile ? "MEGA file" : "MEGA folder" } ?? "MEGA"
    }

    /// A direct link plays at once. A single MEGA file is opened first to learn its name and key.
    private func play(_ v: SavedVideo) {
        guard v.isMega else { presenter.playLink(v); return }
        guard let link = MegaLink.parse(v.url) else { errorText = "This MEGA link is not valid."; return }
        opening = v.id
        Task {
            defer { opening = nil }
            do {
                let folder = try await MegaStore.shared.folder(for: link)
                let handle = link.kind == .file ? link.id : link.sub
                guard let node = handle.flatMap({ folder.node($0) }) else { errorText = "That file is no longer in the MEGA link."; return }
                presenter.playMega(v, node: node, folder: folder)
            } catch { errorText = error.localizedDescription }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { editing = EditTarget(video: nil) } label: {
                Label("Add video", systemImage: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("video-add")

            if library.videos.isEmpty {
                EmptyState(title: "No saved videos", message: "Add a name and a link and it plays right here. It also shows up on your other devices.", systemImage: "play.rectangle")
            } else {
                ForEach(library.videos) { v in
                    HStack(spacing: 0) {
                        rowButton(v)

                        Menu {
                            Button { editing = EditTarget(video: v) } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { deleting = v } label: { Label("Delete", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.text2)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Options for \(v.name)")
                    }
                    .padding(.leading, 14)
                    .padding(.vertical, 6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 16)
        .sheet(item: $editing) { VideoEditorView(video: $0.video) }
        .alert("Can't open this", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .confirmationDialog("Delete \(deleting?.name ?? "video")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let v = deleting { library.removeVideo(v.id) } }
        } message: {
            Text("It is removed from every device signed in to this profile.")
        }
    }
}

struct VideoEditorView: View {
    let video: SavedVideo?

    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var link = ""
    @State private var errorText: String?
    @State private var checking = false
    @FocusState private var focus: Field?
    private enum Field { case name, link }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Kicker(text: "Name")
                        TextField(MegaLink.parse(link) == nil ? "Name" : "Name (optional for MEGA)", text: $name)
                            .font(.system(size: 18, weight: .semibold))
                            .textInputAutocapitalization(.words)
                            .focused($focus, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focus = .link }
                            .padding(14).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
                            .onChange(of: name) { _, v in if v.count > 80 { name = String(v.prefix(80)) } }
                            .accessibilityIdentifier("video-name")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Kicker(text: "Link")
                            Spacer()
                            PasteButton(payloadType: String.self) { strings in
                                if let s = strings.first { link = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                            }
                            .labelStyle(.titleOnly)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                        }
                        TextField("https://", text: $link, axis: .vertical)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(1...4)
                            .focused($focus, equals: .link)
                            .submitLabel(.done)
                            .padding(14).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityIdentifier("video-link")
                        if let kind = detectedKind {
                            Label(kind.text, systemImage: kind.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(kind.good ? .white : Theme.accent)
                        }
                        Text("A video file, a stream (m3u8), a web page with its own player, or a MEGA folder or file link.")
                            .font(.footnote).foregroundStyle(Theme.dim)
                    }
                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(Theme.accent) }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle(video == nil ? "Add video" : "Edit video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { if checking { ProgressView() } else { Text("Save").fontWeight(.semibold) } }
                        .disabled(checking)
                        .disabled(checking || link.trimmingCharacters(in: .whitespaces).isEmpty || (MegaLink.parse(link) == nil && name.trimmingCharacters(in: .whitespaces).isEmpty))
                        .accessibilityIdentifier("video-save")
                }
            }
        }
        .presentationBackground(Theme.bg)
        .onAppear {
            guard name.isEmpty, link.isEmpty else { return }
            name = video?.name ?? ""
            link = video?.url ?? ""
            if video == nil { focus = .name }
        }
    }

    private var detectedKind: (text: String, icon: String, good: Bool)? {
        let t = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let m = MegaLink.parse(t) { return (m.isSingleFile ? "MEGA file found" : "MEGA folder found. You pick what to watch from its list.", "checkmark.circle.fill", true) }
        if Self.clean(t) != nil { return ("Direct link", "link", true) }
        return ("Not a link yet", "exclamationmark.circle", false)
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let mega = MegaLink.parse(link) {
            // Check that the link works (and learn the folder's name) before keeping it.
            checking = true
            errorText = nil
            Task {
                defer { checking = false }
                do {
                    let folder = try await MegaStore.shared.folder(for: mega)
                    library.saveVideo(id: video?.id, name: n.isEmpty ? folder.rootName : n, url: mega.canonical, type: "mega")
                    dismiss()
                } catch { errorText = error.localizedDescription }
            }
            return
        }
        guard let url = Self.clean(link) else { errorText = "Enter a web link that starts with http or https."; return }
        library.saveVideo(id: video?.id, name: n, url: url)
        dismiss()
    }

    /// Accepts "example.com/x" too; only web links are allowed.
    static func clean(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            if s.contains("://") { return nil }
            s = "https://" + s
        }
        guard let u = URL(string: s), let host = u.host(), host.contains(".") || host == "localhost", s.count <= 900 else { return nil }
        return s
    }
}

// MARK: - MEGA folder

/// The videos inside a saved MEGA folder: pick one to play. Folders open in place and Back climbs out.
struct MegaFolderView: View {
    let videoID: String
    let folder: String?

    @Environment(Library.self) private var library
    @Environment(PlayerPresenter.self) private var presenter
    @State private var state: Load = .loading
    @State private var notice: String?

    enum Load { case loading, failed(String), ready(MegaFolder) }

    private var video: SavedVideo? { library.videos.first { $0.id == videoID } }
    private var link: MegaLink? { video.flatMap { MegaLink.parse($0.url) } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                switch state {
                case .loading:
                    HStack(spacing: 12) { ProgressView(); Text("Opening MEGA").foregroundStyle(Theme.text2) }
                        .frame(maxWidth: .infinity).padding(.top, 80)
                case .failed(let message):
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(Theme.text2)
                        Text(message).multilineTextAlignment(.center).foregroundStyle(Theme.text2)
                        Button("Try again") { Task { await load(force: true) } }.buttonStyle(.glass)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 70).padding(.horizontal, 24)
                case .ready(let f):
                    content(f)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .background(Theme.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(force: false) }
        .alert("Can't play this here", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(notice ?? "") }
    }

    private var title: String {
        if case .ready(let f) = state, let folder, let n = f.node(folder) { return n.name }
        return video?.name ?? "MEGA"
    }

    @ViewBuilder private func content(_ f: MegaFolder) -> some View {
        let parent = folder.flatMap { f.node($0) != nil ? $0 : nil } ?? ""
        let tree = f.listing(of: parent)
        // If the folder tree can't be followed, still show every video there is.
        let items = tree.isEmpty && parent.isEmpty ? f.allVideos : tree
        VStack(alignment: .leading, spacing: 6) {
            Kicker(text: (["MEGA"] + (folder.map { Array(f.path(to: $0).dropLast()) } ?? [])).joined(separator: "  /  "))
            Text(title).font(.system(size: 30, weight: .heavy)).lineLimit(2)
            let vids = items.filter { !$0.isDir }.count
            let dirs = items.count - vids
            if !items.isEmpty {
                Text([vids > 0 ? "\(vids) video\(vids == 1 ? "" : "s")" : nil, dirs > 0 ? "\(dirs) folder\(dirs == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .font(.system(size: 14)).foregroundStyle(Theme.dim)
            }
        }
        .padding(.top, 8).padding(.bottom, 10)

        if items.isEmpty {
            EmptyState(title: "No videos here", message: "No video files were found. " + f.inventory, systemImage: "film")
        }
        ForEach(items) { n in
            if n.isDir {
                NavigationLink(value: Route.mega(videoID: videoID, folder: n.id)) { row(n, f) }.buttonStyle(.plain)
                    .accessibilityIdentifier("mega-folder-\(n.name)")
            } else {
                Button { play(n, f) } label: { row(n, f) }.buttonStyle(.plain)
                    .accessibilityIdentifier("mega-\(n.name)")
            }
        }
    }

    private func row(_ n: MegaNode, _ f: MegaFolder) -> some View {
        let phone = n.isDir || MegaFormat.playsOnPhone(n.name)
        return HStack(spacing: 14) {
            Image(systemName: n.isDir ? "folder.fill" : "play.fill")
                .font(.system(size: 17))
                .foregroundStyle(n.isDir ? Color(red: 0.94, green: 0.71, blue: 0.16) : Theme.text2)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(n.name).font(.system(size: 16, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                if !n.isDir {
                    let where_ = f.path(to: n.parent).joined(separator: " / ")
                    Text(where_.isEmpty ? Self.size(n.size) : where_ + " \u{00B7} " + Self.size(n.size)).font(.system(size: 13)).foregroundStyle(Theme.dim).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if n.isDir {
                Text("\(f.videoCount(in: n.id))").font(.system(size: 14)).foregroundStyle(Theme.dim)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.dim)
            } else if !phone {
                Text("TV ONLY").font(.system(size: 10, weight: .bold)).tracking(1.1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .opacity(phone ? 1 : 0.55)
        .padding(.horizontal, 14).padding(.vertical, 13)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    private func play(_ n: MegaNode, _ f: MegaFolder) {
        guard MegaFormat.playsOnPhone(n.name) else {
            notice = "iPhone can't play .\(MegaFormat.ext(n.name)) files. They play on your TV, or convert them to MP4."
            return
        }
        if let video { presenter.playMega(video, node: n, folder: f) }
    }

    private static func size(_ n: Int64) -> String {
        n >= 1_073_741_824 ? String(format: "%.1f GB", Double(n) / 1_073_741_824) : n >= 1_048_576 ? "\(n / 1_048_576) MB" : "\(max(1, n / 1024)) KB"
    }

    private func load(force: Bool) async {
        guard let link else { state = .failed("This MEGA link is not valid."); return }
        if force { await MegaStore.shared.forget(link) }
        state = .loading
        do { state = .ready(try await MegaStore.shared.folder(for: link)) }
        catch { state = .failed(error.localizedDescription) }
    }
}
