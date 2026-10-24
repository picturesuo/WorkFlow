import SwiftUI
import UniformTypeIdentifiers

/// Paste or drop a finished document, choose its mode, and learn. Learned
/// preferences apply to that mode at once and stay listed here to switch
/// off, delete, or reset.
struct CorrectionLearningCard: View {
    @StateObject private var session: CorrectionLearningSession
    @AppStorage private var preferencesData: Data
    @AppStorage private var learningEnabled: Bool
    @State private var isConfirmingReset = false
    @State private var isChoosingFile = false
    @State private var isDropTargeted = false
    @Environment(\.colorScheme) private var colorScheme
    private let defaults: UserDefaults

    @MainActor
    init(session: CorrectionLearningSession? = nil, defaults: UserDefaults = .standard) {
        _session = StateObject(wrappedValue: session ?? CorrectionLearningSession(
            mode: CustomCleanupFilterStore.currentSnapshot(in: defaults).mode,
            defaults: defaults
        ))
        _preferencesData = AppStorage(wrappedValue: Data(), LearnedPreferenceStore.dataKey, store: defaults)
        _learningEnabled = AppStorage(wrappedValue: true, LearnedPreferenceStore.enabledKey, store: defaults)
        self.defaults = defaults
    }

    private var preferences: [LearnedPreference] {
        LearnedPreferenceStore.preferences(from: preferencesData).filter { $0.mode == session.mode }
    }

    /// Where Learn sends data, stated next to the button that sends it.
    private var disclosure: String {
        let destination = session.destination.isOnThisMac
            ? "\(session.destination.summary), on this Mac"
            : session.destination.summary
        return "Learn sends only the short edits it matches to your History, with a few words around each, to \(destination). The document and any file you add are read on this Mac and not saved."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Learn from finished writing")
                        .font(.headline)
                    Text("Paste or drop a whole document you finished from your dictations and choose its mode. WorkFlow learns your edits and applies them to that mode right away.")
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

            HStack(spacing: 10) {
                Text("Learn for")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Picker("Mode to learn for", selection: $session.mode) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(session.isLearning)
                Spacer(minLength: 0)
            }

            DocumentDropEditor(
                text: $session.document,
                isEditable: !session.isLearning && !session.isLoadingFile && learningEnabled,
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

            HStack(spacing: 10) {
                if session.isLearning {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel") { session.cancel() }
                } else {
                    Button("Learn") { session.learn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.canLearn)
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

            Text(disclosure)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = session.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let report = session.report {
                Text(report.summary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let fileSummary = session.fileSummary {
                Text(fileSummary)
                    .font(.caption)
                    .foregroundColor(session.document.count > CorrectionAligner.maximumDocumentLength ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Text("Learned for \(session.mode.displayName)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Reset \(session.mode.displayName)…", role: .destructive) {
                    isConfirmingReset = true
                }
                .disabled(preferences.isEmpty || session.isLearning)
            }

            if !learningEnabled {
                Text("Learning is off: nothing is learned or applied. Your learned preferences are kept for when you turn it back on.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if preferences.isEmpty {
                Text("Nothing learned for \(session.mode.displayName) yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(preferences) { preference in
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
                    Button(role: .destructive) {
                        LearnedPreferenceStore.delete(preference.id, in: defaults)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Delete this learned preference")
                    .accessibilityLabel("Delete learned preference: \(preference.instruction)")
                }
            }

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
            "Reset what WorkFlow learned for \(session.mode.displayName)?",
            isPresented: $isConfirmingReset
        ) {
            Button("Reset \(session.mode.displayName)", role: .destructive) {
                LearnedPreferenceStore.reset(session.mode, in: defaults)
            }
        } message: {
            Text("Learned preferences for other modes and your custom filters stay as they are.")
        }
    }

    private func detail(for preference: LearnedPreference) -> String {
        var parts = [preference.origin.label, "\(preference.evidence.count) \(preference.evidence.count == 1 ? "edit" : "edits")"]
        if preference.fromLegacyOnly { parts.append("legacy History only") }
        return parts.joined(separator: " · ")
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
