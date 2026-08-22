import AppKit
import Foundation

struct PasteTarget: Equatable, Sendable {
    let pid: pid_t?
    let bundleID: String?
    let appName: String?

    static func captureFrontmost() -> PasteTarget {
        let app = NSWorkspace.shared.frontmostApplication
        return PasteTarget(
            pid: app?.processIdentifier,
            bundleID: app?.bundleIdentifier,
            appName: app?.localizedName
        )
    }
}

enum TargetCleanupBehavior: String, CaseIterable, Codable, Identifiable {
    case inherit
    case enabled
    case disabled

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .inherit: "Use global setting"
        case .enabled: "Always clean"
        case .disabled: "Local transcript only"
        }
    }
}

enum TargetPasteBehavior: String, CaseIterable, Codable, Identifiable {
    case appDefault
    case copyOnly
    case never

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .appDefault: "Use global setting"
        case .copyOnly: "Copy only"
        case .never: "Save only"
        }
    }
}

struct TargetAppRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var cleanupBehavior: TargetCleanupBehavior = .inherit
    var pasteBehavior: TargetPasteBehavior = .appDefault
    var cleanupInstruction = ""
}

enum TargetAppRuleStore {
    static let maximumEntries = 100
    static let maximumBundleIDLength = 255
    static let maximumAppNameLength = 200
    static let maximumInstructionLength = 500

    static func load() -> [TargetAppRule] {
        guard let data = AppPreferences.shared.targetAppRulesData,
              let rules = try? JSONDecoder().decode([TargetAppRule].self, from: data) else {
            return []
        }
        return sanitized(rules)
    }

    static func save(_ rules: [TargetAppRule]) {
        AppPreferences.shared.targetAppRulesData = try? JSONEncoder().encode(sanitized(rules))
    }

    static func sanitized(_ rules: [TargetAppRule]) -> [TargetAppRule] {
        var seenBundleIDs = Set<String>()
        var result: [TargetAppRule] = []

        for var rule in rules {
            let bundleID = String(
                rule.bundleID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(maximumBundleIDLength)
            )
            guard !bundleID.isEmpty,
                  seenBundleIDs.insert(bundleID.lowercased()).inserted else { continue }

            rule.bundleID = bundleID
            rule.appName = String(rule.appName.prefix(maximumAppNameLength))
            rule.cleanupInstruction = String(rule.cleanupInstruction.prefix(maximumInstructionLength))
            result.append(rule)
            if result.count == maximumEntries { break }
        }

        return result
    }

    static func rule(for bundleID: String?, in rules: [TargetAppRule] = load()) -> TargetAppRule? {
        guard let bundleID = bundleID?.lowercased() else { return nil }
        return rules.first { $0.bundleID.lowercased() == bundleID }
    }

    static func cleanupEnabled(rule: TargetAppRule?, globalDefault: Bool) -> Bool {
        switch rule?.cleanupBehavior ?? .inherit {
        case .inherit: globalDefault
        case .enabled: true
        case .disabled: false
        }
    }
}
