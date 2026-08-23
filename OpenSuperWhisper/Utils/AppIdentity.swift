import Foundation

enum AppIdentity {
    static let productName = "WorkFlow"
    // Keep the installed identity stable so existing macOS permissions,
    // preferences, history, and Keychain credentials continue to work.
    static let bundleIdentifier = "com.picturesuo.Chat"
    static let legacyBundleIdentifier = "com.picturesuo.GlowScribe"
}

enum RenamedAppMigration {
    private static let preferencesMigrationKey = "didMigratePreferencesFromGlowScribe"

    static func migratePreferences(
        target: UserDefaults = .standard,
        legacyDomain: [String: Any]? = UserDefaults.standard.persistentDomain(
            forName: AppIdentity.legacyBundleIdentifier
        )
    ) {
        guard !target.bool(forKey: preferencesMigrationKey) else { return }

        if let legacyDomain {
            for (key, value) in legacyDomain where target.object(forKey: key) == nil {
                target.set(value, forKey: key)
            }
        }

        target.set(true, forKey: preferencesMigrationKey)
    }

    static func migrateApplicationSupport(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) throws {
        let root = applicationSupportDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let legacyDirectory = root.appendingPathComponent(AppIdentity.legacyBundleIdentifier)
        let currentDirectory = root.appendingPathComponent(AppIdentity.bundleIdentifier)

        guard fileManager.fileExists(atPath: legacyDirectory.path) else { return }

        if !fileManager.fileExists(atPath: currentDirectory.path) {
            try fileManager.copyItem(at: legacyDirectory, to: currentDirectory)
            return
        }

        for sourceURL in try fileManager.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: nil
        ) {
            let destinationURL = currentDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }
}
