import Foundation
import Security

/// Each key-based provider owns a separate Keychain account, so one provider's
/// key is never sent to another provider's endpoint.
enum CleanupCredentialAccount: String {
    case openAICompatible = "openai-compatible"
    case azureOpenAI = "azure-openai"

    /// Only the OpenAI-compatible key predates the WorkFlow rename.
    var migratesLegacyIdentities: Bool { self == .openAICompatible }
}

enum CleanupCredentialStore {
    private static let lock = NSRecursiveLock()
    private static let service = "\(AppIdentity.bundleIdentifier).cleanup"
    private static let legacyServices = AppIdentity.legacyBundleIdentifiers.map { "\($0).cleanup" }

    static func loadAPIKey(for account: CleanupCredentialAccount = .openAICompatible) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let currentValue = try loadAPIKey(service: service, account: account) {
            if account.migratesLegacyIdentities { deleteLegacyAPIKeys(account: account) }
            return currentValue
        }

        guard account.migratesLegacyIdentities else { return nil }
        for legacyService in legacyServices {
            guard let legacyValue = try loadAPIKey(service: legacyService, account: account) else { continue }
            try saveAPIKey(legacyValue, for: account)
            try? deleteAPIKey(service: legacyService, account: account)
            return legacyValue
        }
        return nil
    }

    private static func loadAPIKey(service: String, account: CleanupCredentialAccount) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw BedrockCredentialStoreError.keychain(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw BedrockCredentialStoreError.invalidData
        }
        return value
    }

    static func saveAPIKey(_ value: String, for account: CleanupCredentialAccount = .openAICompatible) throws {
        lock.lock()
        defer { lock.unlock() }

        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            try deleteAPIKey(for: account)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw BedrockCredentialStoreError.keychain(updateStatus) }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw BedrockCredentialStoreError.keychain(addStatus) }
    }

    static func deleteAPIKey(for account: CleanupCredentialAccount = .openAICompatible) throws {
        lock.lock()
        defer { lock.unlock() }

        try deleteAPIKey(service: service, account: account)
        guard account.migratesLegacyIdentities else { return }
        for legacyService in legacyServices {
            try deleteAPIKey(service: legacyService, account: account)
        }
    }

    private static func deleteLegacyAPIKeys(account: CleanupCredentialAccount) {
        for legacyService in legacyServices {
            try? deleteAPIKey(service: legacyService, account: account)
        }
    }

    private static func deleteAPIKey(service: String, account: CleanupCredentialAccount) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BedrockCredentialStoreError.keychain(status)
        }
    }
}
