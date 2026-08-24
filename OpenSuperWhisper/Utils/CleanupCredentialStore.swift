import Foundation
import Security

enum CleanupCredentialStore {
    private static let service = "\(AppIdentity.bundleIdentifier).cleanup"
    private static let legacyServices = AppIdentity.legacyBundleIdentifiers.map { "\($0).cleanup" }
    private static let account = "openai-compatible"

    static func loadAPIKey() throws -> String? {
        if let currentValue = try loadAPIKey(service: service) {
            return currentValue
        }

        var firstLegacyError: Error?
        for legacyService in legacyServices {
            let legacyValue: String?
            do {
                legacyValue = try loadAPIKey(service: legacyService)
            } catch {
                if firstLegacyError == nil { firstLegacyError = error }
                continue
            }
            guard let legacyValue else { continue }
            try saveAPIKey(legacyValue)
            try? deleteAPIKey(service: legacyService)
            return legacyValue
        }
        if let firstLegacyError { throw firstLegacyError }
        return nil
    }

    private static func loadAPIKey(service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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

    static func saveAPIKey(_ value: String) throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            try deleteAPIKey()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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

    static func deleteAPIKey() throws {
        try deleteAPIKey(service: service)
        for legacyService in legacyServices {
            try deleteAPIKey(service: legacyService)
        }
    }

    private static func deleteAPIKey(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BedrockCredentialStoreError.keychain(status)
        }
    }
}
