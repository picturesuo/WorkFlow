import SwiftUI
import UniformTypeIdentifiers

/// Paste or drop a finished document and learn. Each matched dictation
/// teaches the mode or saved filter it was made with; learned preferences
/// apply at once and stay listed here to switch off, delete, or reset.
struct CorrectionLearningCard: View {
    @StateObject private var session: CorrectionLearningSession
    @AppStorage private var preferencesData: Data
    @AppStorage private var learningEnabled: Bool
    @AppStorage private var filtersData: Data
    @State private var viewedScope: CleanupFilterSelection
    @State private var isConfirmingReset = false
    @State private var isChoosingFile = false
    @State private var isDropTargeted = false
    @State private var showsDetails = false
    @Environment(\.colorScheme) private var colorScheme
    private let defaults: UserDefaults

    static let dictationModeNote = "Only older dictations with no recorded mode teach this mode. It doesn’t change the mode new dictations use."

    static let limitations = "WorkFlow learns spacing, capitalization, fillers such as “um”, semicolons and joined sentences, number style, and contractions. It leaves out edits that change a value or a negation and words swapped for others, but it can’t recognize every change of meaning, so look over what it learns."

    @MainActor
    init(session: CorrectionLearningSession? = nil, defaults: UserDefaults = .standard) {
        let mode = session?.mode ?? CustomCleanupFilterStore.currentSnapshot(in: defaults).mode
        _session = StateObject(wrappedValue: session ?? CorrectionLearningSession(mode: mode, defaults: defaults))
        _preferencesData = AppStorage(wrappedValue: Data(), LearnedPreferenceStore.dataKey, store: defaults)
        _learningEnabled = AppStorage(wrappedValue: true, LearnedPreferenceStore.enabledKey, store: defaults)
        _filtersData = AppStorage(wrappedValue: Data(), CustomCleanupFilterStore.dataKey, store: defaults)
        // The list opens on what new dictations use now.
        _viewedScope = State(initialValue: CustomCleanupFilterStore.currentSelection(in: defaults))
        self.defaults = defaults
    }

    private var filters: [CustomCleanupFilter] { CustomCleanupFilterStore.filters(from: filtersData) }

    /// The mode or filter whose list is shown; a deleted filter falls back to its mode.
    private var viewedTarget: LearningTarget {
        switch viewedScope {
        case .builtIn(let mode): .mode(mode)
        case .custom(let id): filters.first { $0.id == id }.map { .filter($0) } ?? .mode(session.mode)
        }
    }

    private var preferences: [LearnedPreference] {
        LearnedPreferenceStore.preferences(from: preferencesData).filter { $0.target == viewedTarget }
    }

    /// Where Learn sends data, stated next to the button that sends it.
    private var disclosure: String {
        let destination = session.destination.isOnThisMac
            ? "\(session.destination.summary), on this Mac"
            : session.destination.summary
        return "Check matches reads your History on this Mac and sends nothing. Learn sends only the short edits it matches, with a few words around each, to \(destination). The document and any file you add are read on this Mac and not saved."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            DocumentDropEditor(
                text: $session.document,
                isEditable: !session.isBusy && !session.isLoadingFile && learningEnabled,
                isDropTargeted: $isDropTargeted,
                onFileDrop: { session.load($0) }
            )
            .frame(minHeight: 110, maxHeight: 220)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            .overlay(alignment: .topLeading) {
                if session.document.isEmpty {
                    Text("Paste the finished document, or drop a PDF, Word, RTF, or text file")
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isDropTargeted || session.isLoadingFile {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ThemePalette.ink(colorScheme).opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Finished document")

            actions

            Text(disclosure)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            outcome

            if let notice = session.vocabularyNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            learnedList

            fallbackPicker

            Text("New dictations keep their original transcript on this Mac until you delete them from History. Older History has none, so only WorkFlow’s saved text is compared.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: DocumentTextExtractor.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { session.load(urls) }
        }
        .confirmationDialog(
            "Reset what WorkFlow learned for \(viewedTarget.displayName)?",
            isPresented: $isConfirmingReset
        ) {
            Button("Reset \(viewedTarget.displayName)", role: .destructive) {
                LearnedPreferenceStore.reset(viewedTarget, in: defaults)
            }
        } message: {
            Text("Other modes and filters keep what they learned, and saved filter instructions stay as they are.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Learn from finished writing")
                    .font(.headline)
                Text("Paste or drop a document you finished from your dictations, even weeks later. WorkFlow finds those dictations in your History and learns small style preferences for the mode or filter each one used. This is preference learning, not model training: every preference is listed below to switch off or delete.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $learningEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Learn from finished writing")
                .accessibilityValue(learningEnabled ? "On" : "Off")
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if session.isBusy {
                ProgressView()
                    .controlSize(.small)
                Text(session.isChecking ? "Checking History…" : "Learning…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Cancel") { session.cancel() }
            } else {
                Button("Learn") { session.learn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canLearn)
                Button("Check matches") { session.check() }
                    .disabled(!session.canLearn)
                    .help("Find the dictations in this document and show what Learn would send, without sending anything")
                Button("Add File…") { isChoosingFile = true }
                    .disabled(session.isLoadingFile || !learningEnabled)
                    .help("Read the text of a PDF, Word, RTF, OpenDocument, or plain text file")
            }
            if session.isLoadingFile {
                ProgressView()
                    .controlSize(.small)
                Text("Reading file…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("\(session.document.count.formatted()) / \(CorrectionAligner.maximumDocumentLength.formatted())")
                .font(.caption2.monospacedDigit())
                .foregroundColor(session.document.count > CorrectionAligner.maximumDocumentLength ? .orange : .secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private var outcome: some View {
        if let error = session.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let report = session.report {
            Text(report.summary)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if !report.plan.dictations.isEmpty || !report.plan.items.isEmpty {
                DisclosureGroup("Details", isExpanded: $showsDetails) {
                    CorrectionLearningDetails(report: report, destination: session.destination, session: session)
                        .padding(.top, 4)
                }
                .font(.caption)
            }
        } else if let fileSummary = session.fileSummary {
            Text(fileSummary)
                .font(.caption)
                .foregroundColor(session.document.count > CorrectionAligner.maximumDocumentLength ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var learnedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Learned for")
                    .font(.subheadline.weight(.medium))
                    .accessibilityHidden(true)
                // A Picker's hidden title is its VoiceOver name; an extra label would be read twice.
                Picker("Learned preferences for", selection: $viewedScope) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.displayName).tag(CleanupFilterSelection.builtIn(mode))
                    }
                    if !filters.isEmpty {
                        Divider()
                        ForEach(filters) { filter in
                            Text(filter.name).tag(CleanupFilterSelection.custom(filter.id))
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Reset \(viewedTarget.displayName)…", role: .destructive) {
                    isConfirmingReset = true
                }
                .disabled(preferences.isEmpty || session.isBusy)
            }

            if !learningEnabled {
                Text("Learning is off: nothing is learned or applied. Your learned preferences are kept for when you turn it back on.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let applied = preferences.filter { $0.inactivity == nil }
            let retained = preferences.filter { $0.inactivity != nil }
            if preferences.isEmpty {
                Text("Nothing learned for \(viewedTarget.isFilter ? "the \(viewedTarget.displayName) filter" : viewedTarget.displayName) yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(applied) { preference in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { preference.isEnabled },
                        set: { LearnedPreferenceStore.setEnabled(preference.id, $0, in: defaults) }
                    ))
                    .labelsHidden()
                    .accessibilityLabel("Use learned preference: \(preference.instruction)")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preference.instruction)
                            .font(.callout)
                            .foregroundColor(preference.isEnabled && learningEnabled ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail(for: preference))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    deleteButton(preference)
                }
            }

            if !retained.isEmpty {
                Text("Not applied: learned before WorkFlow stopped learning these on its own")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
                ForEach(retained) { preference in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preference.instruction)
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(preference.inactivity == .wordChange
                                 ? "A word swapped for another can change a fact or a name. Move it to Vocabulary if WorkFlow always mishears it."
                                 : "This word is often part of what you mean, as in “I like it”, so WorkFlow doesn’t remove it on its own.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if preference.inactivity == .wordChange {
                            Button("Move to Vocabulary") { session.moveToVocabulary(preference) }
                                .controlSize(.small)
                                .accessibilityLabel("Move to Vocabulary: \(preference.instruction)")
                        }
                        deleteButton(preference)
                    }
                }
            }
        }
    }

    private var fallbackPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Older dictations teach")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Picker("Mode older dictations teach", selection: $session.mode) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .disabled(session.isBusy)
                .accessibilityHint(Self.dictationModeNote)
                Spacer(minLength: 0)
            }
            Text("Newer dictations always teach the mode or filter they were made with. \(Self.dictationModeNote)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.limitations)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deleteButton(_ preference: LearnedPreference) -> some View {
        Button(role: .destructive) {
            LearnedPreferenceStore.delete(preference.id, in: defaults)
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.plain)
        .help("Delete this learned preference")
        .accessibilityLabel("Delete learned preference: \(preference.instruction)")
    }

    private func detail(for preference: LearnedPreference) -> String {
        var parts = [preference.origin.label, "\(preference.evidence.count) \(preference.evidence.count == 1 ? "edit" : "edits")"]
        let sources = preference.sourceRecordingIDs
        if !sources.isEmpty {
            parts.append("\(sources.count) \(sources.count == 1 ? "dictation" : "dictations")")
            let missing = sources.filter(session.missingSources.contains).count
            if missing > 0 { parts.append("\(missing) no longer in History") }
        }
        if preference.fromLegacyOnly { parts.append("legacy History only") }
        return parts.joined(separator: " · ")
    }
}

/// The local details behind one Check matches or Learn: which dictations the
/// document holds and what each teaches, the exact lines sent (or that Learn
/// would send), what was left out and why, word changes for Vocabulary, and
/// what happened to each proposal. Built from memory; nothing here is saved.
struct CorrectionLearningDetails: View {
    let report: CorrectionLearningReport
    let destination: CleanupProviderDestination
    @ObservedObject var session: CorrectionLearningSession

    private var plan: CorrectionLearningPlan { report.plan }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !plan.dictations.isEmpty {
                section("Dictations found") {
                    ForEach(plan.dictations) { dictation in
                        Text("\(dictation.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(scope(dictation.scope))\(dictation.isLegacy ? " · saved text only" : "")")
                    }
                }
            }
            let sending = plan.items.filter { $0.disposition == .send }
            if !sending.isEmpty {
                section(report.status == .ready ? "Learn would send to \(destination.summary)" : "Sent to \(destination.summary)") {
                    ForEach(sending) { item in
                        Text(item.excerpt).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            let held = plan.items.filter { [.later, .alreadyReviewed, .repeated].contains($0.disposition) }
            if !held.isEmpty {
                section("Not sent this time") {
                    ForEach(held) { item in
                        labeled(item.excerpt, reason: heldReason(item))
                    }
                }
            }
            let left = plan.items.filter(\.isLeftOut)
            if !left.isEmpty {
                section("Left out, never sent") {
                    ForEach(left) { item in
                        labeled(item.excerpt, reason: leftReason(item.disposition))
                    }
                }
            }
            if !plan.wordChanges.isEmpty {
                section("Word changes WorkFlow won’t learn on its own") {
                    Text("A word swapped for another can be a fact or a name. Add one to Vocabulary only if WorkFlow always mishears it.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(plan.wordChanges) { change in
                        HStack(spacing: 8) {
                            Text("“\(change.spoken)” → “\(change.replacement)”")
                            Spacer()
                            if session.addedWordChanges.contains(change.id) {
                                Text("Added to Vocabulary").foregroundColor(.secondary)
                            } else {
                                Button("Add to Vocabulary") { session.addToVocabulary(change) }
                                    .controlSize(.small)
                                    .accessibilityLabel("Add to Vocabulary: \(change.spoken) as \(change.replacement)")
                            }
                        }
                    }
                }
            }
            if !report.proposals.isEmpty {
                section("What the provider proposed") {
                    ForEach(Array(report.proposals.enumerated()), id: \.offset) { _, proposal in
                        labeled(proposal.description, reason: status(proposal.status), isExcerpt: false)
                    }
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            content()
        }
    }

    private func labeled(_ text: String, reason: String, isExcerpt: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text).font(isExcerpt ? .caption.monospaced() : .caption).textSelection(.enabled)
            Text(reason).foregroundColor(.secondary)
        }
    }

    private func scope(_ scope: CorrectionLearningPlan.Scope) -> String {
        switch scope {
        case .recorded(let target): target.isFilter ? "teaches the \(target.displayName) filter" : "teaches \(target.displayName)"
        case .fallback(let target): "no recorded mode, teaches \(target.displayName)"
        case .deletedFilter: "made with a filter that was deleted, teaches nothing"
        case .unknownFilter: "made with a saved filter WorkFlow didn’t record, teaches nothing"
        }
    }

    private func heldReason(_ item: CorrectionLearningPlan.Item) -> String {
        switch item.disposition {
        case .alreadyReviewed: "Already reviewed"
        case .repeated: "The same edit again; sent once"
        default:
            if let target = item.target, target != plan.target {
                "For \(target.phrase); select Learn again"
            } else {
                "Past this request’s limit; select Learn again"
            }
        }
    }

    private func leftReason(_ disposition: CorrectionLearningPlan.Disposition) -> String {
        switch disposition {
        case .excluded(.tooLong): "More than a few words changed: a rewrite, not a habit"
        case .excluded(.quoted): "Inside quotation marks"
        case .excluded(.crossesLine): "Words added across a line break may be a heading or column"
        case .excluded(.changesNegation): "Changes a negation"
        case .excluded(.changesValue): "Changes a number or value"
        case .excluded(.wordChange): "A word swapped for another"
        case .excluded(.mixedScope): "Repeated takes made with different modes or filters"
        case .unscoped(.deletedFilter): "Its filter was deleted"
        case .unscoped(_): "Its saved filter wasn’t recorded"
        default: ""
        }
    }

    private func status(_ status: ProposalOutcome.Status) -> String {
        switch status {
        case .learned: "Learned"
        case .reinforced: "Learned again, with more edits"
        case .alreadyLearned: "Already learned"
        case .overLimit: "Not learned: \(LearnedPreferenceStore.maximumRulesPerMode) preferences is the limit"
        case .notShown: "Not learned: none of the cited edits shows it"
        case .notAllowed: "Not learned: this mode or filter already decides it"
        case .redundant: "Not learned: this mode or filter already does it"
        case .wordChange: "Not learned: it swaps a word, which may be a fact or a name"
        case .ambiguousFiller: "Not learned: this word is often content"
        }
    }
}

/// A plain-text editor that hands dropped files to `onFileDrop` instead of
/// inserting their paths, so a PDF dropped on the document is read as text.
struct DocumentDropEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    @Binding var isDropTargeted: Bool
    var onFileDrop: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = FileDropTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.delegate = context.coordinator
        textView.string = text
        textView.registerForDraggedTypes([.fileURL])
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? FileDropTextView else { return }
        if textView.string != text { textView.string = text }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.onTargetChange = { targeted in
            if context.coordinator.parent.isDropTargeted != targeted { context.coordinator.parent.isDropTargeted = targeted }
        }
        textView.onFileDrop = isEditable ? { context.coordinator.parent.onFileDrop($0) } : nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DocumentDropEditor

        init(_ parent: DocumentDropEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

final class FileDropTextView: NSTextView {
    var onFileDrop: (([URL]) -> Void)?
    var onTargetChange: ((Bool) -> Void)?

    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Self.fileURLs(on: sender.draggingPasteboard).isEmpty else { return super.draggingEntered(sender) }
        onTargetChange?(onFileDrop != nil)
        return onFileDrop == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Self.fileURLs(on: sender.draggingPasteboard).isEmpty else { return super.draggingUpdated(sender) }
        return onFileDrop == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChange?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !Self.fileURLs(on: sender.draggingPasteboard).isEmpty else { return super.prepareForDragOperation(sender) }
        return onFileDrop != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onTargetChange?(false)
        guard let onFileDrop else { return false }
        onFileDrop(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, !Self.fileURLs(on: sender.draggingPasteboard).isEmpty { return }
        super.concludeDragOperation(sender)
    }
}
