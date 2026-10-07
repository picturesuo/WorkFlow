import Foundation

/// A saved, user-named writing filter. It always builds on one immutable
/// built-in mode, whose length guards, token budget, and safety contract still
/// apply; the instructions only add bounded style preferences on top.
struct CustomCleanupFilter: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var baseMode: CleanupMode
    var instructions: String
}

/// The writing filter resolved for one dictation. It is captured once, stored
/// with queued recordings, and passed through cleanup unchanged, so editing or
/// switching filters mid-flight cannot alter a request already underway.
struct CleanupFilterSnapshot: Equatable, Sendable {
    let mode: CleanupMode
    let customName: String?
    let customInstructions: String?

    init(mode: CleanupMode, customName: String? = nil, customInstructions: String? = nil) {
        self.mode = mode
        let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let instructions = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty || instructions.isEmpty {
            self.customName = nil
            self.customInstructions = nil
        } else {
            self.customName = name
            self.customInstructions = instructions
        }
    }

    init(filter: CustomCleanupFilter) {
        self.init(mode: filter.baseMode, customName: filter.name, customInstructions: filter.instructions)
    }

    static func builtIn(_ mode: CleanupMode) -> CleanupFilterSnapshot {
        CleanupFilterSnapshot(mode: mode)
    }

    var isCustom: Bool { customName != nil }

    var displayName: String { customName ?? mode.displayName }
}

/// What the writing-mode pickers select: one of the built-ins or a saved filter.
enum CleanupFilterSelection: Hashable {
    case builtIn(CleanupMode)
    case custom(UUID)

    private static let customPrefix = "custom:"

    /// Stable string form for menu items.
    var tag: String {
        switch self {
        case .builtIn(let mode): mode.rawValue
        case .custom(let id): Self.customPrefix + id.uuidString
        }
    }

    init?(tag: String) {
        if tag.hasPrefix(Self.customPrefix) {
            guard let id = UUID(uuidString: String(tag.dropFirst(Self.customPrefix.count))) else { return nil }
            self = .custom(id)
        } else if let mode = CleanupMode(rawValue: tag) {
            self = .builtIn(mode)
        } else {
            return nil
        }
    }
}

enum CustomCleanupFilterValidationError: LocalizedError, Equatable {
    case emptyName
    case nameTooLong
    case duplicateName
    case reservedName
    case emptyInstructions
    case instructionsTooLong
    case tooManyFilters

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Give the filter a name."
        case .nameTooLong:
            "Keep the name to \(CustomCleanupFilterStore.maximumNameLength) characters or fewer."
        case .duplicateName:
            "Another filter already uses this name."
        case .reservedName:
            "Everyday, Technical, and Homework are built-in modes. Choose a different name."
        case .emptyInstructions:
            "Describe what this filter should change, for example “write numbers as digits”."
        case .instructionsTooLong:
            "Keep the instructions to \(CustomCleanupFilterStore.maximumInstructionLength) characters or fewer."
        case .tooManyFilters:
            "You can save up to \(CustomCleanupFilterStore.maximumFilters) custom filters."
        }
    }
}

enum CustomCleanupFilterStore {
    static let maximumFilters = 20
    static let maximumNameLength = 40
    static let maximumInstructionLength = 500

    /// Starting points offered in the editor. They are ordinary filters once saved.
    static let examples: [CustomCleanupFilter] = [
        CustomCleanupFilter(
            name: "Everyday with digits",
            baseMode: .everyday,
            instructions: "Write every number as digits, for example “twenty five” becomes “25”."
        ),
        CustomCleanupFilter(
            name: "Everyday with words",
            baseMode: .everyday,
            instructions: "Spell out numbers as words, for example “25” becomes “twenty-five”."
        ),
        CustomCleanupFilter(
            name: "More hyphens",
            baseMode: .everyday,
            instructions: "Hyphenate compound modifiers before a noun, for example “well known author” becomes “well-known author”."
        )
    ]

    static func load(from defaults: UserDefaults = .standard) -> [CustomCleanupFilter] {
        filters(from: defaults.data(forKey: dataKey))
    }

    static func filters(from data: Data?) -> [CustomCleanupFilter] {
        guard let data, !data.isEmpty,
              let filters = try? JSONDecoder().decode([CustomCleanupFilter].self, from: data) else {
            return []
        }
        return sanitized(filters)
    }

    static func save(_ filters: [CustomCleanupFilter], to defaults: UserDefaults = .standard) {
        let values = sanitized(filters)
        defaults.set(try? JSONEncoder().encode(values), forKey: dataKey)
        // A deleted or renamed selection must never leave a dangling ID, and a
        // selected filter's base mode is mirrored for readers of the base mode.
        let selectedID = defaults.string(forKey: selectedIDKey) ?? ""
        if !selectedID.isEmpty {
            if let selected = values.first(where: { $0.id.uuidString == selectedID }) {
                defaults.set(selected.baseMode.rawValue, forKey: modeKey)
            } else {
                defaults.set("", forKey: selectedIDKey)
            }
        }
    }

    /// Validates a filter about to be created or updated against the others.
    static func validate(
        _ filter: CustomCleanupFilter,
        existing: [CustomCleanupFilter]
    ) throws -> CustomCleanupFilter {
        let name = filter.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = filter.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CustomCleanupFilterValidationError.emptyName }
        guard name.count <= maximumNameLength else { throw CustomCleanupFilterValidationError.nameTooLong }
        guard !CleanupMode.allCases.contains(where: {
            $0.displayName.caseInsensitiveCompare(name) == .orderedSame
        }) else { throw CustomCleanupFilterValidationError.reservedName }
        guard !existing.contains(where: {
            $0.id != filter.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { throw CustomCleanupFilterValidationError.duplicateName }
        guard !instructions.isEmpty else { throw CustomCleanupFilterValidationError.emptyInstructions }
        guard instructions.count <= maximumInstructionLength else {
            throw CustomCleanupFilterValidationError.instructionsTooLong
        }
        let isNew = !existing.contains { $0.id == filter.id }
        guard !isNew || existing.count < maximumFilters else {
            throw CustomCleanupFilterValidationError.tooManyFilters
        }
        return CustomCleanupFilter(id: filter.id, name: name, baseMode: filter.baseMode, instructions: instructions)
    }

    /// Inserts or replaces a validated filter and persists the list.
    @discardableResult
    static func upsert(
        _ filter: CustomCleanupFilter,
        in defaults: UserDefaults = .standard
    ) throws -> [CustomCleanupFilter] {
        var filters = load(from: defaults)
        let valid = try validate(filter, existing: filters)
        if let index = filters.firstIndex(where: { $0.id == valid.id }) {
            filters[index] = valid
        } else {
            filters.append(valid)
        }
        save(filters, to: defaults)
        return filters
    }

    @discardableResult
    static func delete(id: UUID, in defaults: UserDefaults = .standard) -> [CustomCleanupFilter] {
        let filters = load(from: defaults).filter { $0.id != id }
        save(filters, to: defaults)
        return filters
    }

    static func select(_ selection: CleanupFilterSelection, in defaults: UserDefaults = .standard) {
        switch selection {
        case .builtIn(let mode):
            defaults.set(mode.rawValue, forKey: modeKey)
            defaults.set("", forKey: selectedIDKey)
        case .custom(let id):
            guard let filter = load(from: defaults).first(where: { $0.id == id }) else { return }
            defaults.set(filter.baseMode.rawValue, forKey: modeKey)
            defaults.set(id.uuidString, forKey: selectedIDKey)
        }
    }

    static func currentSelection(
        in defaults: UserDefaults = .standard,
        filters: [CustomCleanupFilter]? = nil
    ) -> CleanupFilterSelection {
        selection(
            selectedID: defaults.string(forKey: selectedIDKey) ?? "",
            modeRawValue: defaults.string(forKey: modeKey) ?? "",
            filters: filters ?? load(from: defaults)
        )
    }

    static func selection(
        selectedID: String,
        modeRawValue: String,
        filters: [CustomCleanupFilter]
    ) -> CleanupFilterSelection {
        if let id = UUID(uuidString: selectedID), filters.contains(where: { $0.id == id }) {
            return .custom(id)
        }
        return .builtIn(CleanupMode(rawValue: modeRawValue) ?? .everyday)
    }

    /// Resolves the selection once for a dictation. A selected filter that no
    /// longer exists safely resolves to the base built-in mode.
    static func currentSnapshot(in defaults: UserDefaults = .standard) -> CleanupFilterSnapshot {
        let filters = load(from: defaults)
        switch currentSelection(in: defaults, filters: filters) {
        case .custom(let id):
            if let filter = filters.first(where: { $0.id == id }) {
                return CleanupFilterSnapshot(filter: filter)
            }
            return .builtIn(baseMode(in: defaults))
        case .builtIn(let mode):
            return .builtIn(mode)
        }
    }

    static func sanitized(_ filters: [CustomCleanupFilter]) -> [CustomCleanupFilter] {
        var seenIDs = Set<UUID>()
        var seenNames = Set<String>()
        var result: [CustomCleanupFilter] = []
        for var filter in filters {
            filter.name = String(filter.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumNameLength))
            filter.instructions = String(
                filter.instructions.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumInstructionLength)
            )
            guard !filter.name.isEmpty, !filter.instructions.isEmpty,
                  seenIDs.insert(filter.id).inserted,
                  seenNames.insert(filter.name.lowercased()).inserted else { continue }
            result.append(filter)
            if result.count == maximumFilters { break }
        }
        return result
    }

    private static func baseMode(in defaults: UserDefaults) -> CleanupMode {
        CleanupMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .everyday
    }

    static let dataKey = "customCleanupFiltersData"
    static let selectedIDKey = "selectedCustomCleanupFilterID"
    static let modeKey = "cleanupMode"
}
