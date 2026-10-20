import SwiftUI

/// Paste a finished document, choose its mode, and learn. Learned
/// preferences apply to that mode at once and stay listed here to switch
/// off, delete, or reset.
struct CorrectionLearningCard: View {
    @StateObject private var session: CorrectionLearningSession
    @AppStorage private var preferencesData: Data
    @AppStorage private var learningEnabled: Bool
    @State private var isConfirmingReset = false
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

    private var disclosure: String {
        let destination = session.destination.isOnThisMac
            ? "\(session.destination.summary), on this Mac"
            : session.destination.summary
        return "WorkFlow matches the document to your History on this Mac. Only the short edits it can match, with a few words around each, are sent to \(destination). The document itself is not saved. New dictations keep their original transcript on this Mac until you delete them from History; older History has no original, so only WorkFlow's saved text is compared."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Learn from finished writing")
                        .font(.headline)
                    Text("Paste a whole document you finished from your dictations and choose its mode. WorkFlow learns your edits and applies them to that mode right away.")
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

            Picker("Mode", selection: $session.mode) {
                ForEach(CleanupMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(session.isLearning)
            .accessibilityLabel("Mode to learn for")

            TextEditor(text: $session.document)
                .font(.body)
                .frame(minHeight: 110, maxHeight: 220)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .overlay(alignment: .topLeading) {
                    if session.document.isEmpty {
                        Text("Paste the finished document")
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(session.isLearning || !learningEnabled)
                .accessibilityLabel("Finished document")

            Text(disclosure)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if session.isLearning {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel") { session.cancel() }
                } else {
                    Button("Learn") { session.learn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.canLearn)
                }
                Text("\(session.document.count) / \(CorrectionAligner.maximumDocumentLength)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(session.document.count > CorrectionAligner.maximumDocumentLength ? .orange : .secondary)
                Spacer()
            }

            if let error = session.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let report = session.report {
                Text(report.summary)
                    .font(.caption)
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
