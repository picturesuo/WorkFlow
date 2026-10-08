import AppKit
import SwiftUI

/// Observes the writing-mode preferences so every picker stays in sync with
/// the menu bar and settings, including saved custom filters.
struct WritingFilterPreferences: DynamicProperty {
    @AppStorage(CustomCleanupFilterStore.modeKey) private var modeRawValue = CleanupMode.everyday.rawValue
    @AppStorage(CustomCleanupFilterStore.selectedIDKey) private var selectedFilterID = ""
    @AppStorage(CustomCleanupFilterStore.dataKey) private var filtersData = Data()

    var filters: [CustomCleanupFilter] {
        CustomCleanupFilterStore.filters(from: filtersData)
    }

    var selection: CleanupFilterSelection {
        CustomCleanupFilterStore.selection(
            selectedID: selectedFilterID,
            modeRawValue: modeRawValue,
            filters: filters
        )
    }

    var selectionBinding: Binding<CleanupFilterSelection> {
        Binding(
            get: { selection },
            set: { value in
                CustomCleanupFilterStore.select(value)
                NotificationCenter.default.post(name: .cleanupModeChanged, object: nil)
            }
        )
    }

    var selectionDescription: String {
        switch selection {
        case .builtIn(let mode):
            return mode.description
        case .custom(let id):
            guard let filter = filters.first(where: { $0.id == id }) else { return "" }
            return "Based on \(filter.baseMode.displayName): \(filter.instructions)"
        }
    }
}

/// Built-in modes stay a segmented control until the user saves a custom
/// filter; then a menu keeps every option reachable at any window width.
struct WritingFilterPicker: View {
    @Binding var selection: CleanupFilterSelection
    let customFilters: [CustomCleanupFilter]

    var body: some View {
        if customFilters.isEmpty {
            Picker("Writing mode", selection: $selection) {
                builtInOptions
            }
            .pickerStyle(.segmented)
        } else {
            Picker("Writing mode", selection: $selection) {
                Section("Built-in") { builtInOptions }
                Section("Custom filters") {
                    ForEach(customFilters) { filter in
                        Text(filter.name).tag(CleanupFilterSelection.custom(filter.id))
                    }
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var builtInOptions: some View {
        ForEach(CleanupMode.allCases) { mode in
            Text(mode.displayName).tag(CleanupFilterSelection.builtIn(mode))
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

    init(writingFilter: WritingFilterPreferences, newDraft: CustomCleanupFilter? = nil) {
        self.writingFilter = writingFilter
        _draft = State(initialValue: newDraft)
        _isNewDraft = State(initialValue: newDraft != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom filters")
                        .font(.headline)
                    Text("Start from Everyday, Technical, or Homework, then describe what to change in plain language. Meaning, names, values, paths, and identifiers always stay intact.")
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
                                CustomCleanupFilter(name: example.name, baseMode: example.baseMode, instructions: example.instructions),
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

            ForEach(writingFilter.filters) { filter in
                if let draft, !isNewDraft, draft.id == filter.id {
                    editor(for: draft)
                } else {
                    row(for: filter)
                }
            }
        }
        .sheet(item: $assistant) { presentation in
            FilterAssistantSheet(session: presentation.session, voice: presentation.voice) {
                assistant = nil
            }
        }
    }

    private func row(for filter: CustomCleanupFilter) -> some View {
        let isSelected = writingFilter.selection == .custom(filter.id)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(filter.name)
                        .font(.subheadline.weight(.semibold))
                    Text("Based on \(filter.baseMode.displayName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(filter.instructions)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isSelected {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.accentColor)
            } else {
                Button("Use") { writingFilter.selectionBinding.wrappedValue = .custom(filter.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Use \(filter.name)")
            }
            Button {
                openAssistant(.existing(filter))
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.plain)
            .disabled(draft != nil)
            .help("Improve with AI")
            .accessibilityLabel("Improve \(filter.name) with AI")
            Button {
                startDraft(filter, isNew: false)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .disabled(draft != nil)
            .help("Edit filter")
            .accessibilityLabel("Edit \(filter.name)")
            Button(role: .destructive) {
                CustomCleanupFilterStore.delete(id: filter.id)
                NotificationCenter.default.post(name: .cleanupModeChanged, object: nil)
            } label: {
                Image(systemName: "trash")
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
                    Text("What to change, e.g. “Write all numbers as digits and use more hyphens.”")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
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
        .background(Color.accentColor.opacity(0.06))
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
