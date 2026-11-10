import Foundation

/// A saved, user-named writing filter. It always builds on one immutable
/// built-in mode, whose length guards, token budget, and safety contract still
/// apply; the instructions only add bounded style preferences on top.
struct CustomCleanupFilter: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var baseMode: CleanupMode
    var instructions: String
    /// Writes spoken quantities as digits on this Mac after cleanup, the way
    /// Homework does, because cleanup models do not reliably follow a digits
    /// instruction. It is an explicit choice, never read from the wording.
    var writesDigits = false
    /// Phrases that let Auto pick this filter when at least two different
    /// ones come up in one dictation. Unused unless Auto is chosen.
    var triggers: [String] = []
}

extension CustomCleanupFilter {
    static let writesDigitsHelp = "Done on this Mac after cleanup, as in Homework: “fifteen percent” → “15%”, “one hundred five” → “105”."

    /// The base mode, the digits choice, and the instructions, for menus and pickers.
    var summary: String {
        "Based on \(baseMode.displayName)\(writesDigits ? ", quantities as digits" : ""): \(instructions)"
    }

    /// Filters saved before `writesDigits` existed decode with it off.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseMode = try container.decode(CleanupMode.self, forKey: .baseMode)
        instructions = try container.decode(String.self, forKey: .instructions)
        writesDigits = try container.decodeIfPresent(Bool.self, forKey: .writesDigits) ?? false
        // Filters saved before trigger phrases existed decode with none.
        triggers = try container.decodeIfPresent([String].self, forKey: .triggers) ?? []
    }
}

/// The writing filter resolved for one dictation. It is captured once, stored
/// with queued recordings, and passed through cleanup unchanged, so editing or
/// switching filters mid-flight cannot alter a request already underway.
struct CleanupFilterSnapshot: Equatable, Sendable {
    let mode: CleanupMode
    let customName: String?
    let customInstructions: String?
    /// The saved filter's identity, when one was selected, so evidence can
    /// follow a filter across renames.
    let customID: UUID?
    /// Whether the saved filter writes spoken quantities as digits.
    let customWritesDigits: Bool
    /// Enabled learned preferences for this built-in mode or saved filter.
    /// A saved filter carries only what it learned itself, never a built-in
    /// mode's, and its saved instructions are never changed.
    let learned: [LearnedPreference]

    init(
        mode: CleanupMode,
        customName: String? = nil,
        customInstructions: String? = nil,
        customID: UUID? = nil,
        customWritesDigits: Bool = false,
        learned: [LearnedPreference] = []
    ) {
        self.mode = mode
        let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let instructions = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty || instructions.isEmpty {
            self.customName = nil
            self.customInstructions = nil
            self.customID = nil
            self.customWritesDigits = false
            self.learned = learned.filter { $0.mode == mode && $0.filterID == nil && $0.isEnabled && $0.isApplicable }
        } else {
            self.customName = name
            self.customInstructions = instructions
            self.customID = customID
            self.customWritesDigits = customWritesDigits
            self.learned = customID.map { id in
                learned.filter { $0.filterID == id && $0.isEnabled && $0.isApplicable }
            } ?? []
        }
    }

    init(filter: CustomCleanupFilter, learned: [LearnedPreference] = []) {
        self.init(
            mode: filter.baseMode,
            customName: filter.name,
            customInstructions: filter.instructions,
            customID: filter.id,
            customWritesDigits: filter.writesDigits,
            learned: learned
        )
    }

    static func builtIn(_ mode: CleanupMode) -> CleanupFilterSnapshot {
        CleanupFilterSnapshot(mode: mode)
    }

    var isCustom: Bool { customName != nil }

    /// Whether a successful cleanup finishes spoken quantities as digits on
    /// this Mac: built-in Homework always does, a saved filter when it says
    /// so, and either when it learned the person writes digits.
    var writesDigits: Bool {
        (isCustom ? customWritesDigits : mode == .homework) || learned.contains { $0.kind == .digits }
    }

    /// Whether cleanup may choose a number style, which also turns on the
    /// guard's requirement that every spoken number survives.
    var allowsNumberFormatting: Bool {
        isCustom || mode.formatsNumbers || learned.contains(where: \.formatsNumbers)
    }

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

/// Keeps a growing collection of saved filters easy to scan: short lists
/// stay flat, longer ones group by the built-in mode they build on, and the
/// Settings list can be searched.
enum FilterCollection {
    /// Up to this many saved filters, menus and lists stay flat.
    static let flatLimit = 8

    static func isLarge(_ filters: [CustomCleanupFilter]) -> Bool {
        filters.count > flatLimit
    }

    /// Saved filters by base mode, in the built-in modes' order, each group
    /// sorted by name. Empty groups are left out.
    static func grouped(_ filters: [CustomCleanupFilter]) -> [(mode: CleanupMode, filters: [CustomCleanupFilter])] {
        CleanupMode.allCases.compactMap { mode in
            let group = filters
                .filter { $0.baseMode == mode }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return group.isEmpty ? nil : (mode, group)
        }
    }

    /// Filters whose name, instructions, phrases, or base mode contain every
    /// word of the query, ignoring case and accents.
    static func search(_ filters: [CustomCleanupFilter], query: String) -> [CustomCleanupFilter] {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        guard !terms.isEmpty else { return filters }
        return filters.filter { filter in
            let haystack = ([filter.name, filter.instructions, filter.baseMode.displayName] + filter.triggers)
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return terms.allSatisfy { haystack.contains($0) }
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
    case tooManyTriggers
    case triggerTooLong(String)
    case triggerTooCommon(String)
    case duplicateTrigger(String, otherFilter: String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Give the filter a name."
        case .nameTooLong:
            "Keep the name to \(CustomCleanupFilterStore.maximumNameLength) characters or fewer."
        case .duplicateName:
            "Another filter already uses this name."
        case .reservedName:
            "Everyday, Technical, Homework, and Writing are built-in modes. Choose a different name."
        case .emptyInstructions:
            "Describe what this filter should change, for example “use more hyphens”."
        case .instructionsTooLong:
            "Keep the instructions to \(CustomCleanupFilterStore.maximumInstructionLength) characters or fewer."
        case .tooManyFilters:
            "You can save up to \(CustomCleanupFilterStore.maximumFilters) custom filters."
        case .tooManyTriggers:
            "Use up to \(FilterTriggers.maximumCount) phrases for automatic choice."
        case .triggerTooLong(let phrase):
            "Keep “\(phrase)” to \(FilterTriggers.maximumWords) words and \(FilterTriggers.maximumLength) characters."
        case .triggerTooCommon(let phrase):
            "“\(phrase)” comes up in almost any dictation. Choose a word specific to this kind of writing."
        case .duplicateTrigger(let phrase, let other):
            "“\(phrase)” already picks “\(other)”. Each phrase can pick only one filter."
        }
    }
}

enum CustomCleanupFilterStore {
    static let maximumFilters = 50
    static let maximumNameLength = 40
    static let maximumInstructionLength = 500

    /// Starting points offered in the editor. They are ordinary filters once saved.
    static let examples: [CustomCleanupFilter] = [
        CustomCleanupFilter(
            name: "Everyday with digits",
            baseMode: .everyday,
            instructions: "Write every number as digits, for example “twenty five” becomes “25”.",
            writesDigits: true
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
        let triggers = try FilterTriggers.validated(
            filter.triggers, others: existing.filter { $0.id != filter.id }
        )
        return CustomCleanupFilter(
            id: filter.id, name: name, baseMode: filter.baseMode, instructions: instructions,
            writesDigits: filter.writesDigits, triggers: triggers
        )
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

    /// Deletes a filter and what it learned.
    @discardableResult
    static func delete(id: UUID, in defaults: UserDefaults = .standard) -> [CustomCleanupFilter] {
        let filters = load(from: defaults).filter { $0.id != id }
        save(filters, to: defaults)
        LearnedPreferenceStore.removeFilter(id, in: defaults)
        return filters
    }

    /// Picks a filter by hand. That always wins, so it also turns Auto off.
    static func select(_ selection: CleanupFilterSelection, in defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: FilterAutoSettings.enabledKey) {
            defaults.set(false, forKey: FilterAutoSettings.enabledKey)
        }
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
                return CleanupFilterSnapshot(
                    filter: filter,
                    learned: LearnedPreferenceStore.activePreferences(for: .filter(filter), in: defaults)
                )
            }
            return builtInSnapshot(baseMode(in: defaults), in: defaults)
        case .builtIn(let mode):
            return builtInSnapshot(mode, in: defaults)
        }
    }

    private static func builtInSnapshot(_ mode: CleanupMode, in defaults: UserDefaults) -> CleanupFilterSnapshot {
        CleanupFilterSnapshot(mode: mode, learned: LearnedPreferenceStore.activePreferences(for: mode, in: defaults))
    }

    static func sanitized(_ filters: [CustomCleanupFilter]) -> [CustomCleanupFilter] {
        var seenIDs = Set<UUID>()
        var seenNames = Set<String>()
        var seenTriggers = Set<String>()
        var result: [CustomCleanupFilter] = []
        for var filter in filters {
            filter.name = String(filter.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumNameLength))
            filter.instructions = String(
                filter.instructions.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumInstructionLength)
            )
            guard !filter.name.isEmpty, !filter.instructions.isEmpty,
                  seenIDs.insert(filter.id).inserted,
                  seenNames.insert(filter.name.lowercased()).inserted else { continue }
            // Stored phrases that are invalid, or already pick an earlier
            // filter, are dropped rather than costing the filter itself.
            filter.triggers = FilterTriggers.sanitized(filter.triggers, excluding: &seenTriggers)
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
