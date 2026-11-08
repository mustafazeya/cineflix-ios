import Foundation
import CommonCrypto
import Security

// MARK: - Models

struct SyncProfile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var color: String
    var avatar: String
    var kids: Bool
    var maxRating: String?
    var hasPin: Bool
    var position: Int
}

struct SyncChange: Codable, Hashable, Sendable {
    var kind: String
    var key: String
    var value: JSONValue?
    var updatedAt: Double
    var deleted: Bool
    var rev: Int?

    var queueKey: String { "\(kind)/\(key)" }

    init(kind: String, key: String, value: JSONValue?, updatedAt: Double, deleted: Bool = false, rev: Int? = nil) {
        self.kind = kind
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.rev = rev
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        key = try c.decode(String.self, forKey: .key)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        rev = try c.decodeIfPresent(Int.self, forKey: .rev)
    }
}

struct SyncError: LocalizedError, Sendable {
    let status: Int          // 0 = could not reach the server
    let code: String?
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Password stretching and token storage

nonisolated enum SyncCrypto {
    /// PBKDF2-SHA256, salt "cineflix:<lowercase email>", 600,000 rounds, 32 bytes as hex. Every CineFlix app uses this exact recipe, so the
    /// password never leaves the device: the server only ever sees this result.
    static func deriveKey(password: String, email: String) -> String {
        let salt = Array("cineflix:\(email)".utf8)
        let pw = Array(password.utf8).map { Int8(bitPattern: $0) }
        var out = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &out, out.count)
        precondition(status == kCCSuccess)
        return out.map { String(format: "%02x", $0) }.joined()
    }
}

enum Keychain {
    private static let service = "se.cineflix.sync"

    static func save(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}

// MARK: - API

/// The CineFlix Sync server API (see the cineflix-sync repository).
struct SyncAPI: Sendable {
    let base: URL
    var token: String?

    private struct Envelope: Decodable { struct Err: Decodable { let code: String?; let message: String? }; let error: Err? }
    private struct Empty: Decodable {}

    struct Auth: Decodable { struct Account: Decodable { let id: String; let email: String }; let token: String; let account: Account }
    struct ProfilesResponse: Decodable { let profiles: [SyncProfile] }
    struct PullResponse: Decodable { let rev: Int; let more: Bool; let changes: [SyncChange] }
    struct PushResponse: Decodable { let rev: Int; let applied: Int; let stale: [String] }
    struct Lookup: Decodable { let code: String; let deviceName: String; let platform: String }

    private func request<T: Decodable>(_ method: String, _ path: String, body: [String: JSONValue]? = nil, auth: Bool = true) async throws -> T {
        guard let url = URL(string: path, relativeTo: base) else { throw SyncError(status: 0, code: nil, message: "The sync server address is not valid") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONEncoder().encode(body) }
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw SyncError(status: 0, code: nil, message: "Cannot reach the sync server") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let env = try? JSONDecoder().decode(Envelope.self, from: data)
            throw SyncError(status: status, code: env?.error?.code, message: env?.error?.message ?? "Request failed (\(status))")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // Account
    func register(email: String, key: String, signupCode: String, device: String) async throws -> Auth {
        try await request("POST", "/v1/auth/register", body: ["email": .string(email), "key": .string(key), "signupCode": .string(signupCode),
                                                             "deviceName": .string(device), "platform": .string("ios")], auth: false)
    }
    func login(email: String, key: String, device: String) async throws -> Auth {
        try await request("POST", "/v1/auth/login", body: ["email": .string(email), "key": .string(key), "deviceName": .string(device), "platform": .string("ios")], auth: false)
    }
    func logout() async throws { let _: Empty = try await request("POST", "/v1/auth/logout", body: [:]) }

    // Profiles
    func profiles() async throws -> [SyncProfile] { let r: ProfilesResponse = try await request("GET", "/v1/profiles"); return r.profiles }
    func createProfile(name: String, avatar: String, color: String) async throws -> SyncProfile {
        try await request("POST", "/v1/profiles", body: ["name": .string(name), "avatar": .string(avatar), "color": .string(color)])
    }
    func updateProfile(id: String, name: String, avatar: String, color: String) async throws -> SyncProfile {
        try await request("PATCH", "/v1/profiles/\(id)", body: ["name": .string(name), "avatar": .string(avatar), "color": .string(color)])
    }
    func deleteProfile(id: String) async throws { let _: Empty = try await request("DELETE", "/v1/profiles/\(id)", body: [:]) }

    // Sync
    func pull(profile: String, since: Int) async throws -> PullResponse { try await request("GET", "/v1/profiles/\(profile)/sync?since=\(since)") }
    func push(profile: String, changes: [SyncChange]) async throws -> PushResponse {
        let items = changes.map { c -> JSONValue in
            var o: [String: JSONValue] = ["kind": .string(c.kind), "key": .string(c.key), "updatedAt": .number(c.updatedAt), "deleted": .bool(c.deleted)]
            if !c.deleted { o["value"] = c.value ?? .null }
            return .object(o)
        }
        return try await request("POST", "/v1/profiles/\(profile)/sync", body: ["changes": .array(items)])
    }

    // Connecting a TV
    func lookupTV(code: String) async throws -> Lookup {
        let q = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
        return try await request("GET", "/v1/pair/lookup?code=\(q)")
    }
    func approveTV(code: String) async throws { let _: Empty = try await request("POST", "/v1/pair/approve", body: ["userCode": .string(code)]) }
}
