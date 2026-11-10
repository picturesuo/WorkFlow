import Foundation

enum AppIdentity {
    static let productName = "WorkFlow"
    static let bundleIdentifier = "com.picturesuo.WorkFlow"
    static let legacyBundleIdentifiers = [
        "com.picturesuo.Chat",
        "com.picturesuo.GlowScribe"
    ]
}

enum RenamedAppMigration {
    private static let preferencesMigrationKey = "didMigratePreferencesToWorkFlow"
    static let didMigrateFromChatKey = "didMigrateFromChatIdentity"

    static func migratePreferences(
        target: UserDefaults = .standard,
        legacyDomains: [(identifier: String, values: [String: Any])]? = nil
    ) {
        guard !target.bool(forKey: preferencesMigrationKey) else { return }

        let domains = legacyDomains ?? AppIdentity.legacyBundleIdentifiers.compactMap { identifier in
            UserDefaults.standard.persistentDomain(forName: identifier).map {
                (identifier: identifier, values: $0)
            }
        }

        for domain in domains {
            for (key, value) in domain.values where target.object(forKey: key) == nil {
                target.set(value, forKey: key)
            }
        }

        if domains.contains(where: { $0.identifier == "com.picturesuo.Chat" }) {
            target.set(true, forKey: didMigrateFromChatKey)
        }
        target.set(true, forKey: preferencesMigrationKey)
    }

    static func migrateApplicationSupport(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        legacyIdentifiers: [String] = AppIdentity.legacyBundleIdentifiers
    ) throws {
        let root = applicationSupportDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let currentDirectory = root.appendingPathComponent(AppIdentity.bundleIdentifier)

        for identifier in legacyIdentifiers {
            let legacyDirectory = root.appendingPathComponent(identifier)
            guard fileManager.fileExists(atPath: legacyDirectory.path) else { continue }
            try copyMissingContents(
                from: legacyDirectory,
                to: currentDirectory,
                fileManager: fileManager
            )
        }
    }

    private static func copyMissingContents(
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        fileManager: FileManager
    ) throws {
        if !fileManager.fileExists(atPath: destinationDirectory.path) {
            try fileManager.copyItem(at: sourceDirectory, to: destinationDirectory)
            return
        }

        for sourceURL in try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if !fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            } else if try sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try copyMissingContents(
                    from: sourceURL,
                    to: destinationURL,
                    fileManager: fileManager
                )
            }
        }
    }
}
