import AppKit
import SwiftUI

/// Observes the writing-mode preferences so every picker stays in sync with
/// the menu bar and settings, including saved custom filters and Auto.
struct WritingFilterPreferences: DynamicProperty {
    @AppStorage(CustomCleanupFilterStore.modeKey) private var modeRawValue = CleanupMode.everyday.rawValue
    @AppStorage(CustomCleanupFilterStore.selectedIDKey) private var selectedFilterID = ""
    @AppStorage(CustomCleanupFilterStore.dataKey) private var filtersData = Data()
    @AppStorage(FilterAutoSettings.enabledKey) private var autoEnabled = false
    @AppStorage(FilterAutoSettings.fallbackKey) private var autoFallbackTag = ""

    var filters: [CustomCleanupFilter] {
        CustomCleanupFilterStore.filters(from: filtersData)
    }

    /// The filter picked by hand. Under Auto it is kept, unused, for when
    /// Auto is turned off.
    var selection: CleanupFilterSelection {
        CustomCleanupFilterStore.selection(
            selectedID: selectedFilterID,
            modeRawValue: modeRawValue,
            filters: filters
        )
    }

    /// Picking a filter by hand also turns Auto off.
    var selectionBinding: Binding<CleanupFilterSelection> {
        Binding(
            get: { selection },
            set: { value in
                CustomCleanupFilterStore.select(value)
                NotificationCenter.default.post(name: .cleanupModeChanged, object: nil)
            }
        )
    }

    var isAuto: Bool { autoEnabled }

    var autoBinding: Binding<Bool> {
        Binding(
            get: { autoEnabled },
            set: { value in
                FilterAutoSettings.setEnabled(value)
                NotificationCenter.default.post(name: .cleanupModeChanged, object: nil)
            }
        )
    }

    var autoFallback: CleanupFilterSelection {
        FilterAutoSettings.fallback(tag: autoFallbackTag, manual: selection, filters: filters)
    }

    var autoFallbackBinding: Binding<CleanupFilterSelection> {
        Binding(
            get: { autoFallback },
            set: { value in
                FilterAutoSettings.setFallback(value)
                NotificationCenter.default.post(name: .cleanupModeChanged, object: nil)
            }
        )
    }

    func name(of selection: CleanupFilterSelection) -> String {
        switch selection {
        case .builtIn(let mode): mode.displayName
        case .custom(let id): filters.first { $0.id == id }?.name ?? CleanupMode.everyday.displayName
        }
    }

    /// How many saved filters Auto can switch to on their phrases.
    var autoCandidateCount: Int {
        filters.filter { $0.triggers.count >= FilterTriggers.minimumDistinctHits }.count
    }

    var selectionDescription: String {
        if autoEnabled {
            let unsure = name(of: autoFallback)
            return "Auto: a saved filter is used when two of its phrases come up in a dictation; otherwise \(unsure)."
        }
        switch selection {
        case .builtIn(let mode):
            return mode.description
        case .custom(let id):
            guard let filter = filters.first(where: { $0.id == id }) else { return "" }
            return filter.summary
        }
    }
}

/// Built-in modes stay a segmented control until the user saves a custom
/// filter or turns on Auto; then a menu keeps every option reachable at any
/// window width. Past a handful of saved filters, they move into submenus
/// by base mode so the menu stays short.
struct WritingFilterPicker: View {
    @Binding var selection: CleanupFilterSelection
    let customFilters: [CustomCleanupFilter]
    /// Offers Auto when given.
    var isAuto: Binding<Bool>?
    var autoFallbackName = CleanupMode.everyday.displayName

    static let autoTitle = "Auto"

    private enum Choice: Hashable {
        case auto
        case filter(CleanupFilterSelection)
    }

    private var choice: Binding<Choice> {
        Binding(
            get: { isAuto?.wrappedValue == true ? .auto : .filter(selection) },
            set: { value in
                switch value {
                case .auto: isAuto?.wrappedValue = true
                case .filter(let filter): selection = filter
                }
            }
        )
    }

    private var autoIsOn: Bool { isAuto?.wrappedValue == true }

    var body: some View {
        if customFilters.isEmpty, !autoIsOn {
            Picker("Dictation mode", selection: $selection) {
                builtInOptions
            }
            .pickerStyle(.segmented)
        } else if !FilterCollection.isLarge(customFilters) {
            Picker("Dictation mode", selection: choice) {
                autoOption
                Section("Built-in") { choiceBuiltInOptions }
                if !customFilters.isEmpty {
                    Section("Custom filters") {
                        ForEach(customFilters) { filter in
                            Text(filter.name).tag(Choice.filter(.custom(filter.id)))
                        }
                    }
                }
            }
            .pickerStyle(.menu)
        } else {
            // A native pull-down built like the menu bar's, so a long
            // collection is one level of submenus by base mode.
            LargeFilterMenuButton(
                title: currentTitle,
                filters: customFilters,
                isAuto: autoIsOn,
                selection: selection,
                fallbackName: autoFallbackName,
                onChoose: { choice.wrappedValue = $0.map(Choice.filter) ?? .auto }
            )
            .fixedSize()
            .accessibilityLabel("Dictation mode")
        }
    }

    private var currentTitle: String {
        if autoIsOn { return Self.autoTitle }
        switch selection {
        case .builtIn(let mode): return mode.displayName
        case .custom(let id): return customFilters.first { $0.id == id }?.name ?? CleanupMode.everyday.displayName
        }
    }

    @ViewBuilder
    private var autoOption: some View {
        if isAuto != nil {
            Section("Picks a saved filter from what you say; else \(autoFallbackName)") {
                Text(Self.autoTitle).tag(Choice.auto)
            }
        }
    }

    private var builtInOptions: some View {
        ForEach(CleanupMode.allCases) { mode in
            Text(mode.displayName).tag(CleanupFilterSelection.builtIn(mode))
        }
    }

    private var choiceBuiltInOptions: some View {
        ForEach(CleanupMode.allCases) { mode in
            Text(mode.displayName).tag(Choice.filter(.builtIn(mode)))
        }
    }
}

/// The Dictation mode button for a large collection: the same menu as the
/// menu bar's Dictation Mode, in a native pull-down. `onChoose` receives a
/// filter, or nil for Auto.
struct LargeFilterMenuButton: NSViewRepresentable {
    let title: String
    let filters: [CustomCleanupFilter]
    let isAuto: Bool
    let selection: CleanupFilterSelection
    let fallbackName: String
    let onChoose: (CleanupFilterSelection?) -> Void

    @MainActor
    final class Coordinator: NSObject {
        var onChoose: (CleanupFilterSelection?) -> Void = { _ in }

        @objc func select(_ sender: NSMenuItem) {
            guard let tag = sender.representedObject as? String,
                  let selection = CleanupFilterSelection(tag: tag) else { return }
            onChoose(selection)
        }

        @objc func selectAuto() { onChoose(nil) }

        @objc func manage() { SettingsRequest.open(pane: .cleanup) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .push
        button.controlSize = .regular
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onChoose = onChoose
        let menu = NSMenu()
        menu.autoenablesItems = false
        // A pull-down shows its first item as the button's title.
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        DictationModeMenu.populate(
            menu,
            filters: filters,
            isAuto: isAuto,
            selection: selection,
            fallback: .builtIn(.everyday),
            fallbackName: fallbackName,
            target: context.coordinator,
            select: #selector(Coordinator.select(_:)),
            selectAuto: #selector(Coordinator.selectAuto),
            manage: #selector(Coordinator.manage)
        )
        button.menu = menu
        button.setTitle(title)
        button.setAccessibilityValue(title)
    }
}

/// Phrases that let Auto pick a filter, typed as one comma-separated line.
/// The text is kept as typed, so a trailing comma or space is never eaten.
struct FilterTriggerField: View {
    @Binding var phrases: [String]
    var accessibilityLabel = "Trigger phrases"
    @State private var text: String

    init(phrases: Binding<[String]>, accessibilityLabel: String = "Trigger phrases") {
        _phrases = phrases
        self.accessibilityLabel = accessibilityLabel
        _text = State(initialValue: FilterTriggers.joined(phrases.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Use automatically when I mention… e.g. derivative, integral", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(accessibilityLabel)
            }
            Text("Optional. With Dictation mode set to Auto, this filter is used when two of these phrases come up in one dictation. Separate phrases with commas.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: text) { _, value in
            let parsed = FilterTriggers.parse(value)
            if parsed != phrases { phrases = parsed }
        }
        .onChange(of: phrases) { _, value in
            if FilterTriggers.parse(text) != value { text = FilterTriggers.joined(value) }
        }
    }
}

/// Create, edit, use, and delete saved custom writing filters.
struct CustomCleanupFiltersCard: View {
    let writingFilter: WritingFilterPreferences

    @State private var draft: CustomCleanupFilter?
    @State private var isNewDraft: Bool
    @State private var errorMessage = ""
    @State private var assistant: FilterAssistantPresentation?
    @State private var pendingDeletion: CustomCleanupFilter?
    @State private var query = ""
    /// Groups opened or closed by hand; nil until the first toggle, when
    /// only the group holding the filter in use is open.
    @State private var expandedGroups: Set<CleanupMode>?
    @Environment(\.colorScheme) private var colorScheme

    init(writingFilter: WritingFilterPreferences, newDraft: CustomCleanupFilter? = nil) {
        self.writingFilter = writingFilter
        _draft = State(initialValue: newDraft)
        _isNewDraft = State(initialValue: newDraft != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Custom filters")
                            .font(.headline)
                        if !writingFilter.filters.isEmpty {
                            Text("\(writingFilter.filters.count) of \(CustomCleanupFilterStore.maximumFilters)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("Start from Everyday, Technical, Homework, or Writing, then describe what to change in plain language. Meaning, names, values, paths, and identifiers always stay intact.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    openAssistant(.new)
                } label: {
                    Label("Create with AI", systemImage: "sparkles")
                }
                .fixedSize()
                .disabled(draft != nil || writingFilter.filters.count >= CustomCleanupFilterStore.maximumFilters)
                .help("Describe a filter or paste a finished example, then review the AI's draft")
                Menu {
                    Button("Blank filter") {
                        startDraft(CustomCleanupFilter(name: "", baseMode: .everyday, instructions: ""), isNew: true)
                    }
                    Divider()
                    ForEach(CustomCleanupFilterStore.examples, id: \.name) { example in
                        Button(example.name) {
                            startDraft(
                                CustomCleanupFilter(
                                    name: example.name, baseMode: example.baseMode,
                                    instructions: example.instructions, writesDigits: example.writesDigits
                                ),
                                isNew: true
                            )
                        }
                    }
                } label: {
                    Label("New filter", systemImage: "plus")
                }
                .fixedSize()
                .disabled(draft != nil || writingFilter.filters.count >= CustomCleanupFilterStore.maximumFilters)
                .accessibilityLabel("New custom filter")
            }

            if let draft, isNewDraft {
                editor(for: draft)
            }

            if writingFilter.filters.isEmpty, draft == nil {
                Text("Example: “Everyday with digits” writes “twenty five” as “25”, while keeping your Everyday tone.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if writingFilter.filters.count >= CustomCleanupFilterStore.maximumFilters {
                Text("You’ve saved \(CustomCleanupFilterStore.maximumFilters) filters, the most WorkFlow keeps. Delete one to add another.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if FilterCollection.isLarge(writingFilter.filters) {
                TextField("Search \(writingFilter.filters.count) filters by name, phrase, or rule", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search custom filters")
                let matches = FilterCollection.search(writingFilter.filters, query: query)
                if matches.isEmpty {
                    Text("No filter matches “\(query)”.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(FilterCollection.grouped(matches), id: \.mode) { group in
                    let isExpanded = isExpanded(group.mode, filters: group.filters)
                    Button {
                        var groups = expandedGroups ?? defaultExpandedGroups
                        if groups.contains(group.mode) { groups.remove(group.mode) } else { groups.insert(group.mode) }
                        expandedGroups = groups
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .frame(width: 10)
                            Text("Based on \(group.mode.displayName) · \(group.filters.count)")
                                .font(.caption.weight(.semibold))
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .disabled(!query.isEmpty)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel("Based on \(group.mode.displayName), \(group.filters.count) filters")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    if isExpanded {
                        ForEach(group.filters) { filter in
                            rowOrEditor(for: filter)
                        }
                    }
                }
            } else {
                ForEach(writingFilter.filters) { filter in
                    rowOrEditor(for: filter)
                }
            }
        }
        .sheet(item: $assistant) { presentation in
            FilterAssistantSheet(session: presentation.session, voice: presentation.voice) {
                assistant = nil
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { filter in
            Button("Delete Filter", role: .destructive) {
                CustomCleanupFilterStore.delete(id: filter.id)
                NotificationCenter.default.post(name: .cleanupModeChanged, object: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: { filter in
            if writingFilter.selection == .custom(filter.id) {
                Text("New dictations switch to \(filter.baseMode.displayName). History keeps the dictations this filter already cleaned up.")
            } else {
                Text("History keeps the dictations this filter already cleaned up.")
            }
        }
    }

    /// The group holding the filter in use, or Auto's fallback, starts open.
    private var defaultExpandedGroups: Set<CleanupMode> {
        let selection = writingFilter.isAuto ? writingFilter.autoFallback : writingFilter.selection
        guard case .custom(let id) = selection,
              let filter = writingFilter.filters.first(where: { $0.id == id }) else { return [] }
        return [filter.baseMode]
    }

    /// Searching opens every group with a match, and a filter being edited
    /// keeps its group open.
    private func isExpanded(_ mode: CleanupMode, filters: [CustomCleanupFilter]) -> Bool {
        if !query.isEmpty { return true }
        if let draft, !isNewDraft, filters.contains(where: { $0.id == draft.id }) { return true }
        return (expandedGroups ?? defaultExpandedGroups).contains(mode)
    }

    @ViewBuilder
    private func rowOrEditor(for filter: CustomCleanupFilter) -> some View {
        if let draft, !isNewDraft, draft.id == filter.id {
            editor(for: draft)
        } else {
            row(for: filter)
        }
    }

    private func row(for filter: CustomCleanupFilter) -> some View {
        let isAuto = writingFilter.isAuto
        let isSelected = !isAuto && writingFilter.selection == .custom(filter.id)
        let isFallback = isAuto && writingFilter.autoFallback == .custom(filter.id)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(filter.name)
                        .font(.subheadline.weight(.semibold))
                    Text(filter.writesDigits ? "Based on \(filter.baseMode.displayName) · digits" : "Based on \(filter.baseMode.displayName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(filter.instructions)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !filter.triggers.isEmpty {
                    Label(filter.triggers.joined(separator: " · "), systemImage: "wand.and.stars")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help(filter.triggers.count >= FilterTriggers.minimumDistinctHits
                              ? "Under Auto, used when two of these come up in one dictation"
                              : "Add one more phrase: Auto needs two of them in one dictation")
                        .accessibilityLabel("Auto phrases: \(filter.triggers.joined(separator: ", "))")
                }
            }
            Spacer()
            if isFallback {
                Label("Auto when unsure", systemImage: "wand.and.stars")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
            }
            if isSelected {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundColor(ThemePalette.linkText(colorScheme))
            } else {
                Button("Use") { writingFilter.selectionBinding.wrappedValue = .custom(filter.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Use \(filter.name)")
            }
            Button {
                openAssistant(.existing(filter))
            } label: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(draft != nil)
            .help("Improve with AI")
            .accessibilityLabel("Improve \(filter.name) with AI")
            Button {
                startDraft(filter, isNew: false)
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(draft != nil)
            .help("Edit filter")
            .accessibilityLabel("Edit \(filter.name)")
            Button(role: .destructive) {
                pendingDeletion = filter
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(draft != nil)
            .help("Delete filter")
            .accessibilityLabel("Delete \(filter.name)")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func editor(for filter: CustomCleanupFilter) -> some View {
        let binding = Binding<CustomCleanupFilter>(
            get: { draft ?? filter },
            set: { draft = $0; errorMessage = "" }
        )
        let count = binding.wrappedValue.instructions.trimmingCharacters(in: .whitespacesAndNewlines).count
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Filter name, e.g. Everyday with digits", text: binding.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter name")
            Picker("Based on", selection: binding.baseMode) {
                ForEach(CleanupMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Write quantities as digits", isOn: binding.writesDigits)
                    .toggleStyle(.checkbox)
                Text(CustomCleanupFilter.writesDigitsHelp)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: binding.instructions)
                    .font(.callout)
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    .accessibilityLabel("What this filter should change")
                if binding.wrappedValue.instructions.isEmpty {
                    Text("What to change, e.g. “Use more hyphens and capitalize product names.”")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            FilterTriggerField(phrases: binding.triggers)
                .id(filter.id)
            HStack {
                if !errorMessage.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("\(count)/\(CustomCleanupFilterStore.maximumInstructionLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(count > CustomCleanupFilterStore.maximumInstructionLength ? .orange : .secondary)
                Button("Cancel") { endDraft() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveDraft() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(ThemePalette.ink(colorScheme).opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func openAssistant(_ target: FilterAssistantSession.Target) {
        assistant = FilterAssistantPresentation(
            session: FilterAssistantSession(target: target),
            voice: FilterAssistantVoiceInput()
        )
    }

    private func startDraft(_ filter: CustomCleanupFilter, isNew: Bool) {
        draft = filter
        isNewDraft = isNew
        errorMessage = ""
    }

    private func endDraft() {
        draft = nil
        isNewDraft = false
        errorMessage = ""
    }

    private func saveDraft() {
        guard let draft else { return }
        do {
            try CustomCleanupFilterStore.upsert(draft)
            NotificationCenter.default.post(name: .cleanupModeChanged, object: nil)
            endDraft()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Keeps one assistant conversation alive for the lifetime of its sheet.
struct FilterAssistantPresentation: Identifiable {
    let id = UUID()
    let session: FilterAssistantSession
    let voice: FilterAssistantVoiceInput
}
