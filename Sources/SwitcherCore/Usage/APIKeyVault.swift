import Foundation
import LocalAuthentication
import Security

public protocol APIKeyVaultAuthenticator: Sendable {
    func evaluatePolicy() async throws
}

public struct DeviceOwnerAPIKeyAuthenticator: APIKeyVaultAuthenticator {
    public init() {}

    public func evaluatePolicy() async throws {
        let context = LAContext()
        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: L10n.t(.apiKeyAuthReason)) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? APIKeyVaultError.authenticationFailed)
                }
            }
        }
    }
}

/// The three SecItem calls the vault uses, behind a seam so tests run against a memory store
/// (audit B-06). Queries are SecItem dictionaries; results are attribute/item dictionaries.
public protocol KeychainItemStore: Sendable {
    func add(_ query: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func delete(_ query: [String: Any]) -> OSStatus
}

public struct SystemKeychainItemStore: KeychainItemStore {
    public init() {}
    public func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    public func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var result: CFTypeRef?
        return (SecItemCopyMatching(query as CFDictionary, &result), result)
    }
    public func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

public enum APIKeyVaultError: Error, Equatable, Sendable {
    case invalidEntry
    case authenticationFailed
    case keychainFailure
    case keyUnavailable
}

public final class KeychainAPIKeyVault: APIKeyVault, @unchecked Sendable {
    public static let service = "com.jaysong.usageswitch.apikey"
    private let store: KeychainItemStore
    private let authenticator: APIKeyVaultAuthenticator

    public init(store: KeychainItemStore = SystemKeychainItemStore(),
                authenticator: APIKeyVaultAuthenticator = DeviceOwnerAPIKeyAuthenticator()) {
        self.store = store
        self.authenticator = authenticator
    }

    public func register(vendor: APIVendor, nickname: String, key: String) async throws -> APIKeyEntry {
        let cleanNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanNickname.isEmpty, cleanNickname.count <= 80,
              !key.isEmpty, key.count <= 16_384 else { throw APIKeyVaultError.invalidEntry }
        try await authenticator.evaluatePolicy()
        let id = Self.account(vendor: vendor, id: UUID())
        let createdAt = Date()
        let entry = APIKeyEntry(id: id, vendor: vendor, nickname: cleanNickname,
                                last4: String(key.suffix(4)), createdAt: createdAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadata = KeychainMetadata(nickname: entry.nickname, last4: entry.last4, createdAt: createdAt)
        guard let label = String(data: try encoder.encode(metadata), encoding: .utf8) else {
            throw APIKeyVaultError.invalidEntry
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(key.utf8),
        ]
        guard store.add(query) == errSecSuccess else {
            throw APIKeyVaultError.keychainFailure
        }
        return entry
    }

    public func list() async throws -> [APIKeyEntry] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        let (status, result) = store.copyMatching(query)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw APIKeyVaultError.keychainFailure }
        let items = result as? [[String: Any]] ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Entries whose stored label no longer decodes are reported, not dropped: the user must
        // still be able to see and delete them (audit B-06).
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let (vendor, _) = Self.parseAccount(account) else { return nil }
            if let label = item[kSecAttrLabel as String] as? String,
               let metadata = try? decoder.decode(KeychainMetadata.self, from: Data(label.utf8)) {
                return APIKeyEntry(id: account, vendor: vendor, nickname: metadata.nickname,
                                   last4: metadata.last4, createdAt: metadata.createdAt)
            }
            return APIKeyEntry(id: account, vendor: vendor,
                               nickname: String(account.suffix(4)),
                               last4: "", createdAt: .distantPast, isUnreadable: true)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func reveal(id: String) async throws -> String {
        try await authenticator.evaluatePolicy()
        return try password(id: id)
    }

    private func password(id: String) throws -> String {
        guard Self.parseAccount(id) != nil else { throw APIKeyVaultError.invalidEntry }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let (status, result) = store.copyMatching(query)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw APIKeyVaultError.keyUnavailable
        }
        return value
    }

    public func delete(id: String) async throws {
        try await authenticator.evaluatePolicy()
        guard Self.parseAccount(id) != nil else { throw APIKeyVaultError.invalidEntry }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
        ]
        let status = store.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyVaultError.keychainFailure
        }
    }

    private struct KeychainMetadata: Codable {
        let nickname: String
        let last4: String
        let createdAt: Date
    }

    private static func account(vendor: APIVendor, id: UUID) -> String {
        "\(vendor.rawValue):\(id.uuidString)"
    }

    private static func parseAccount(_ account: String) -> (APIVendor, UUID)? {
        let parts = account.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let vendor = APIVendor(rawValue: String(parts[0])),
              let id = UUID(uuidString: String(parts[1])) else { return nil }
        return (vendor, id)
    }
}
