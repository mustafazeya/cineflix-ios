import Foundation
import Observation

/// Account, profiles and sync with a CineFlix Sync server. The app is local-first: everything works offline and without an account
/// (guest). While signed in, edits are queued and sent in the background, changes from other devices are pulled in, and for a conflict the
/// newest edit wins, per item. This follows the same rules as the TV app, so both stay in step.
@MainActor
@Observable
final class SyncService {
    private struct Stored: Codable {
        var server: String?
        var email: String?
        var profileID: String?
        var rev: [String: Int] = [:]
        var profiles: [SyncProfile] = []
        /// 2 = knows My Videos. Older versions skipped those items but still moved past them.
        var schema: Int?
    }

    private(set) var email: String?
    private(set) var profiles: [SyncProfile] = []
    private(set) var activeProfileID: String?
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var pending = 0
    private(set) var isBusy = false
    /// Set when the server rejected this phone's sign-in (signed out from another device, or the password changed).
    private(set) var signedOutNotice = false

    private let library: Library
    private let settings: AppSettings
    private var stored = Stored()
    private var token: String?
    private var meta: [String: Double] = [:]
    private var queue: [String: SyncChange] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private static let stateKey = "cf.sync.state"
    private static let tokenAccount = "token"

    var isSignedIn: Bool { token != nil && stored.server != nil }
    var activeProfile: SyncProfile? { profiles.first { $0.id == activeProfileID } }
    /// Signed in but no profile chosen yet: the "Who's watching?" screen should be shown.
    var needsProfile: Bool { isSignedIn && activeProfile == nil }
    var serverConfigured: Bool { URL(string: settings.syncServer.trimmingCharacters(in: .whitespaces)) != nil && !settings.syncServer.isEmpty }

    init(library: Library, settings: AppSettings) {
        self.library = library
        self.settings = settings
        if let data = UserDefaults.standard.data(forKey: Self.stateKey), let s = try? JSONDecoder().decode(Stored.self, from: data) { stored = s }
        token = Keychain.read(account: Self.tokenAccount)
        if token == nil { stored = Stored() }                       // the token is gone: start clean
        email = stored.email
        profiles = stored.profiles
        activeProfileID = stored.profileID
        if token != nil, (stored.schema ?? 1) < 2 { stored.rev = [:]; stored.schema = 2; saveStored() }   // one full re-download
        library.onChange = { [weak self] change in self?.note(change) }
        if isSignedIn, let id = activeProfileID, activeProfile != nil {
            library.useNamespace(id)
            loadQueue(for: id)
        } else if isSignedIn {
            activeProfileID = nil
        }
    }

    // MARK: Files

    private static func file(_ name: String, _ id: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("sync-\(name)-\(id).json")
    }

    private func saveStored() {
        stored.profileID = activeProfileID
        stored.profiles = profiles
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.stateKey) }
    }

    private func loadQueue(for id: String) {
        meta = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: Self.file("meta", id)))) ?? [:]
        queue = (try? JSONDecoder().decode([String: SyncChange].self, from: Data(contentsOf: Self.file("queue", id)))) ?? [:]
        pending = queue.count
    }

    private func saveMeta() { if let id = activeProfileID, let d = try? JSONEncoder().encode(meta) { try? d.write(to: Self.file("meta", id), options: .atomic) } }
    private func saveQueue() {
        pending = queue.count
        if let id = activeProfileID, let d = try? JSONEncoder().encode(queue) { try? d.write(to: Self.file("queue", id), options: .atomic) }
    }

    // MARK: API access

    private func api(authenticated: Bool = true) throws -> SyncAPI {
        let address = (authenticated ? stored.server : nil) ?? settings.syncServer.trimmingCharacters(in: .whitespaces)
        let trimmed = address.hasSuffix("/") ? String(address.dropLast()) : address
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            throw SyncError(status: 0, code: nil, message: "Add your sync server address in Settings first")
        }
        return SyncAPI(base: url, token: authenticated ? token : nil)
    }

    private func guarded<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() }
        catch let e as SyncError where e.status == 401 { lostSignIn(); throw e }
    }

    // MARK: Sign in and out

    private var deviceName: String { UIDeviceName.value }

    func signIn(email: String, password: String) async throws {
        let mail = email.trimmingCharacters(in: .whitespaces).lowercased()
        let key = await Task.detached(priority: .userInitiated) { SyncCrypto.deriveKey(password: password, email: mail) }.value
        let a = try api(authenticated: false)
        let auth = try await a.login(email: mail, key: key, device: deviceName)
        try await finishSignIn(auth, server: a.base.absoluteString)
    }

    func signUp(email: String, password: String, signupCode: String? = nil) async throws {
        let mail = email.trimmingCharacters(in: .whitespaces).lowercased()
        let code = signupCode?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? settings.syncSignupCode
        guard !code.isEmpty else { throw SyncError(status: 403, code: "bad_signup_code", message: "Enter the sign-up code from the person who runs your sync server") }
        let key = await Task.detached(priority: .userInitiated) { SyncCrypto.deriveKey(password: password, email: mail) }.value
        let a = try api(authenticated: false)
        let auth = try await a.register(email: mail, key: key, signupCode: code, device: deviceName)
        try await finishSignIn(auth, server: a.base.absoluteString)
    }

    private func finishSignIn(_ auth: SyncAPI.Auth, server: String) async throws {
        token = auth.token
        Keychain.save(auth.token, account: Self.tokenAccount)
        stored = Stored(server: server, email: auth.account.email)
        email = auth.account.email
        signedOutNotice = false
        saveStored()
        try await loadProfiles()
    }

    func signOut() async {
        if let a = try? api() { try? await a.logout() }
        clearAccount()
    }

    private func lostSignIn() {
        guard isSignedIn else { return }
        clearAccount()
        signedOutNotice = true
        lastError = "You were signed out. Sign in again to keep syncing."
    }

    private func clearAccount() {
        stopPolling()
        flushTask?.cancel()
        var ids = profiles.map(\.id)
        if let a = activeProfileID, !ids.contains(a) { ids.append(a) }
        library.useNamespace(nil)
        // A shared phone should not keep someone's data after they sign out.
        for id in ids {
            Library.removeData(for: id)
            try? FileManager.default.removeItem(at: Self.file("meta", id))
            try? FileManager.default.removeItem(at: Self.file("queue", id))
        }
        Keychain.delete(account: Self.tokenAccount)
        token = nil
        stored = Stored()
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
        email = nil; profiles = []; activeProfileID = nil; meta = [:]; queue = [:]; pending = 0; lastSync = nil; lastError = nil
    }

    // MARK: Profiles

    @discardableResult
    func loadProfiles() async throws -> [SyncProfile] {
        do {
            let list = try await guarded { try await api().profiles() }
            profiles = list
            saveStored()
            if activeProfileID != nil && activeProfile == nil { activeProfileID = nil }       // the profile was deleted elsewhere
            return list
        } catch let e as SyncError where e.status == 0 && !profiles.isEmpty {
            return profiles                                                                      // offline: use the last known list
        }
    }

    func createProfile(name: String, avatar: String) async throws {
        let color = Avatars.find(avatar).map { String(format: "#%06x", $0.top) } ?? "#3e63dd"
        _ = try await guarded { try await api().createProfile(name: name, avatar: avatar, color: color) }
        try await loadProfiles()
    }

    func updateProfile(_ p: SyncProfile, name: String, avatar: String) async throws {
        let color = Avatars.find(avatar).map { String(format: "#%06x", $0.top) } ?? p.color
        _ = try await guarded { try await api().updateProfile(id: p.id, name: name, avatar: avatar, color: color) }
        try await loadProfiles()
    }

    func deleteProfile(_ p: SyncProfile) async throws {
        try await guarded { try await api().deleteProfile(id: p.id) }
        Library.removeData(for: p.id)
        try? FileManager.default.removeItem(at: Self.file("meta", p.id))
        try? FileManager.default.removeItem(at: Self.file("queue", p.id))
        if activeProfileID == p.id { activeProfileID = nil; library.useNamespace(nil) }
        try await loadProfiles()
    }

    /// Makes a profile the one this phone shows, loads its data and catches up with the server.
    func select(_ p: SyncProfile) async {
        activeProfileID = p.id
        saveStored()
        library.useNamespace(p.id)
        loadQueue(for: p.id)
        startPolling()
        await pull()
        await flush()
    }

    // MARK: Guest data

    var hasGuestData: Bool { !Library.export(namespace: nil).isEmpty }

    private var askedKey: String { "cf.guestAsked.\(email ?? "")" }
    var shouldOfferGuestImport: Bool { !UserDefaults.standard.bool(forKey: askedKey) && hasGuestData }
    func markGuestImportAsked() { UserDefaults.standard.set(true, forKey: askedKey) }

    /// Adds what this phone had before signing in (its list and history) to the chosen profile.
    func importGuestData() async {
        markGuestImportAsked()
        var accepted: [SyncChange] = []
        for c in Library.export(namespace: nil) {
            // Edits already known for this profile are newer than guest data; do not overwrite them.
            if let m = meta[c.queueKey], m >= c.updatedAt { continue }
            meta[c.queueKey] = c.updatedAt
            queue[c.queueKey] = SyncChange(kind: c.kind, key: c.key, value: c.value?.slimmed, updatedAt: c.updatedAt, deleted: false)
            accepted.append(c)
        }
        library.apply(accepted)
        saveMeta(); saveQueue()
        await flush()
    }

    // MARK: Local edits -> queue

    private func note(_ c: SyncChange) {
        guard isSignedIn, activeProfileID != nil else { return }
        meta[c.queueKey] = c.updatedAt
        queue[c.queueKey] = SyncChange(kind: c.kind, key: c.key, value: c.deleted ? nil : c.value?.slimmed, updatedAt: c.updatedAt, deleted: c.deleted)
        saveMeta(); saveQueue()
        scheduleFlush(after: 8)
    }

    private func scheduleFlush(after seconds: Double) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func flush() async {
        guard let pid = activeProfileID, !queue.isEmpty, !isBusy, isSignedIn else { return }
        isBusy = true
        defer { isBusy = false }
        let batch = Array(queue.values.prefix(200))
        do {
            let res = try await guarded { try await api().push(profile: pid, changes: batch) }
            guard pid == activeProfileID else { return }
            for c in batch where queue[c.queueKey]?.updatedAt == c.updatedAt { queue[c.queueKey] = nil }
            saveQueue()
            lastSync = Date(); lastError = nil
            if !queue.isEmpty { scheduleFlush(after: 1) }
            if !res.stale.isEmpty { isBusy = false; await pull() }
        } catch let e as SyncError {
            if e.status != 401 {
                lastError = e.status == 0 ? "Offline. Changes will be sent when the server is reachable." : e.message
                scheduleFlush(after: 60)
            }
        } catch {}
    }

    // MARK: Remote changes -> local

    func pull() async {
        guard let pid = activeProfileID, isSignedIn else { return }
        do {
            var more = true
            while more {
                let since = stored.rev[pid] ?? 0
                let page = try await guarded { try await api().pull(profile: pid, since: since) }
                guard pid == activeProfileID else { return }
                var accepted: [SyncChange] = []
                for c in page.changes {
                    if let m = meta[c.queueKey], m > c.updatedAt { continue }        // this phone has a newer edit
                    meta[c.queueKey] = c.updatedAt
                    if let q = queue[c.queueKey], q.updatedAt <= c.updatedAt { queue[c.queueKey] = nil }
                    accepted.append(c)
                }
                library.apply(accepted)
                stored.rev[pid] = page.rev
                saveStored(); saveMeta(); saveQueue()
                more = page.more
            }
            lastSync = Date(); lastError = nil
        } catch let e as SyncError {
            if e.status != 401 { lastError = e.status == 0 ? "Offline" : e.message }
        } catch {}
    }

    func syncNow() async {
        await flush()
        await pull()
        await flush()
    }

    // MARK: Foreground and background

    func activate() {
        guard isSignedIn, activeProfileID != nil else { return }
        startPolling()
        Task { await pull(); await flush() }
    }

    func deactivate() {
        stopPolling()
        Task { await flush() }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await self?.pull()
            }
        }
    }

    private func stopPolling() { pollTask?.cancel(); pollTask = nil }

    // MARK: Connecting a TV

    /// Looks up the code shown on a TV, and returns the device's name.
    func lookupTV(code: String) async throws -> String {
        try await guarded { try await api().lookupTV(code: code).deviceName }
    }

    func approveTV(code: String) async throws {
        try await guarded { try await api().approveTV(code: code) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private enum UIDeviceName {
    static var value: String { "iPhone" }
}
