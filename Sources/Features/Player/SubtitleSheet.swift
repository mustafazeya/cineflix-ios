import SwiftUI

/// Draws the current subtitle line above the player.
struct SubtitleOverlay: View {
    let controller: SubtitleController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            if let line = controller.cue(at: context.date) {
                Text(SubtitleParser.styled(line))
                    .font(.system(size: 19, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 40)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 92)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Search SubDL for the title being played, pick a subtitle, adjust its delay.
struct SubtitleSheet: View {
    let request: PlaybackRequest
    let controller: SubtitleController

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var results: [SubtitleResult] = []
    @State private var loading = true
    @State private var message: String?
    @State private var language = "ALL"
    @State private var downloading: String?

    private var languages: [String] {
        let list = settings.subLangs.uppercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return list.isEmpty ? ["EN"] : list
    }

    private var storeKey: String { SubtitleStore.key(request.ref, season: request.season, episode: request.episode) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(request.title + (request.subtitle.map { " \u{00B7} \($0)" } ?? ""))
                        .font(.footnote).foregroundStyle(Theme.dim)
                    Text(controller.clockSeen ? "Synced with the video" : "Waiting for the video. Subtitles appear once it plays.")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }

                if controller.isOn {
                    Section("On") {
                        Text("\(controller.lang) \u{00B7} \(controller.name)").font(.subheadline)
                        HStack(spacing: 8) {
                            Text("Delay").foregroundStyle(Theme.text2)
                            Spacer()
                            ForEach([(-5.0, "-5"), (-0.5, "-0.5"), (0.5, "+0.5"), (5.0, "+5")], id: \.0) { d in
                                Button(d.1) { nudge(d.0) }.buttonStyle(.glass).controlSize(.small)
                            }
                        }
                        LabeledContent("Current delay", value: String(format: "%+.1fs", controller.offset))
                        Button("Turn off", role: .destructive) {
                            controller.clear()
                            SubtitleStore.forget(storeKey)
                            dismiss()
                        }
                    }
                }

                Section {
                    if loading {
                        HStack { ProgressView(); Text("Searching...").foregroundStyle(Theme.dim) }
                    } else if let message {
                        Text(message).foregroundStyle(Theme.dim)
                    }
                    ForEach(results) { r in
                        Button { Task { await choose(r) } } label: {
                            HStack(spacing: 12) {
                                Text(r.lang)
                                    .font(.system(size: 12, weight: .bold)).tracking(0.6)
                                    .frame(minWidth: 34)
                                    .padding(.vertical, 3)
                                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name).font(.subheadline).foregroundStyle(.white).lineLimit(2)
                                    let sub = [r.pack ? "Full season zip, episode \(request.episode ?? 0) picked for you" : nil, r.hi ? "Hearing impaired" : nil, r.author.isEmpty ? nil : r.author].compactMap { $0 }.joined(separator: " \u{00B7} ")
                                    if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(Theme.dim) }
                                }
                                Spacer()
                                if downloading == r.id { ProgressView() }
                            }
                        }
                        .disabled(downloading != nil)
                        .accessibilityIdentifier("subtitle-result")
                    }
                } header: {
                    HStack {
                        Text("Results")
                        Spacer()
                        if languages.count > 1 {
                            Menu {
                                Picker("Language", selection: $language) {
                                    Text("All: " + languages.joined(separator: ", ")).tag("ALL")
                                    ForEach(languages, id: \.self) { Text($0).tag($0) }
                                }
                            } label: {
                                Label(language == "ALL" ? languages.joined(separator: ", ") : language, systemImage: "globe")
                                    .font(.footnote)
                            }
                        } else {
                            Label(languages[0], systemImage: "globe").font(.footnote).foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            .navigationTitle("Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: language) { await search() }
        }
        .presentationDetents([.medium, .large])
    }

    private func search() async {
        loading = true
        message = nil
        results = []
        let langs = language == "ALL" ? languages : [language]
        do {
            results = try await SubDL(key: settings.subdlKey).search(request.ref, season: request.season, episode: request.episode, languages: langs)
            if results.isEmpty { message = "No subtitles found for this title in \(langs.joined(separator: ", "))." }
        } catch {
            message = error.localizedDescription
        }
        loading = false
    }

    private func choose(_ r: SubtitleResult) async {
        downloading = r.id
        defer { downloading = nil }
        do {
            let file = try await SubDL(key: settings.subdlKey).download(r, season: request.season, episode: request.episode)
            controller.load(text: file.text, cues: file.cues, name: r.name, lang: r.lang)
            SubtitleStore.save(storeKey, SavedSubtitle(name: r.name, lang: r.lang, text: file.text, offset: 0, at: Date()))
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    private func nudge(_ delta: Double) {
        controller.nudge(delta)
        SubtitleStore.save(storeKey, SavedSubtitle(name: controller.name, lang: controller.lang, text: controller.text, offset: controller.offset, at: Date()))
    }
}
