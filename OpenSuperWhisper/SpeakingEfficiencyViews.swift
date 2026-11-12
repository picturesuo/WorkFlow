import SwiftUI

/// The words each speaking-versus-typing surface shows, kept apart from the
/// views so tests read exactly what a person reads.
struct SpeakingPresentation: Equatable {
    let summary: SpeakingSummary
    let typingWPM: Double

    init(summary: SpeakingSummary, typingWPM: Double) {
        self.summary = summary
        self.typingWPM = SpeakingEfficiency.clampedTypingWPM(typingWPM)
    }

    var hasComparisons: Bool { !summary.counted.isEmpty }

    /// The main window's one line, or nil when there is nothing to say.
    var stripText: String? {
        if let headline = SpeakingFormat.headline(summary.counted, typingWPM: typingWPM) {
            return "This month: \(headline)"
        }
        // Dictations from before active speech was measured are never shown as zero.
        guard summary.exclusions[.speechNotMeasured, default: 0] > 0 else { return nil }
        return "This month: time saved counts from your next dictation"
    }

    var savedValue: String {
        SpeakingFormat.saved(summary.counted.savedSeconds(atWPM: typingWPM))
    }

    var savedDetail: String {
        let counted = summary.counted
        return "Typing the \(SpeakingFormat.words(counted.spokenWords)) you said in \(SpeakingFormat.dictations(counted.count)) at \(SpeakingFormat.wpm(typingWPM)) would take about \(SpeakingFormat.minutes(counted.typingSeconds(atWPM: typingWPM))); you spoke them in \(SpeakingFormat.minutes(counted.activeSpeechSeconds)) of active speech."
    }

    var speedValue: String {
        summary.counted.speedup(atWPM: typingWPM).map(SpeakingFormat.speedup) ?? "—"
    }

    var speedDetail: String {
        "Typing time ÷ active speech, each added up across the same \(SpeakingFormat.dictations(summary.counted.count)) before dividing."
    }

    var activeValue: String {
        SpeakingFormat.minutes(summary.counted.activeSpeechSeconds)
    }

    var activeDetail: String {
        let counted = summary.counted
        var detail = "Estimated by the speech detector on this Mac, out of \(SpeakingFormat.minutes(counted.recordingSeconds)) recorded. Pauses, thinking, and waiting for text aren’t counted."
        if let pace = counted.speakingWPM {
            detail += " Speaking pace while talking: \(SpeakingFormat.wpm(pace))."
        }
        return detail
    }

    /// Present only when some History rows this month are not in the figures.
    var notCountedValue: String? {
        let excluded = summary.excludedCount
        return excluded > 0 ? excluded.formatted() : nil
    }

    var notCountedDetail: String {
        exclusionLines.map { "\($0.label): \($0.count.formatted())" }.joined(separator: " · ")
    }

    var emptyDetail: String {
        if summary.exclusions[.speechNotMeasured, default: 0] > 0 {
            return "Dictations from before WorkFlow measured active speech aren’t counted. Your next dictation starts the count."
        }
        guard summary.excludedCount > 0 else { return "Dictate something and the comparison appears here." }
        return "Nothing this month can be compared yet; see Not counted."
    }

    /// Excluded rows by reason, in a stable order, zero counts left out.
    var exclusionLines: [(label: String, count: Int)] {
        SpeakingExclusion.allCases.compactMap { reason in
            guard let count = summary.exclusions[reason], count > 0 else { return nil }
            return (SpeakingFormat.exclusion(reason), count)
        }
    }

    static let method: [String] = [
        "Active speech is the time the speech detector on this Mac heard you talking. Pauses longer than about a quarter second, thinking, reading, and waiting for the text aren’t counted.",
        "Typing time is the words the recognizer heard ÷ the assumed typing speed. Cleanup that lengthens or shortens the text doesn’t change it.",
        "Time saved is typing time − active speech, in minutes. It can be negative.",
        "× faster is total typing time ÷ total active speech for the same dictations; totals are added up before dividing, never averaged per dictation.",
        "It’s an estimate: the detector can count other voices or a steady hum as speech and can miss whispers. Editing isn’t measured. Meetings, imports, failures, and dictations without measured active speech are left out, and a regenerated dictation keeps its first figures.",
    ]
}

/// Settings → Dictation: this month's comparison, the editable assumption,
/// and how every figure is computed.
struct SpeakingSettingsGroup: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showsMethod = false

    private var presentation: SpeakingPresentation {
        SpeakingPresentation(summary: viewModel.speakingSummary, typingWPM: viewModel.typingBaselineWPM)
    }

    var body: some View {
        SettingsGroup(
            title: "Speaking vs typing this month",
            footer: "Counts and timings only, computed on this Mac. Billing tokens stay under Provider & Cost."
        ) {
            if presentation.hasComparisons {
                valueRow("Time saved", presentation.savedValue, detail: presentation.savedDetail)
                SettingsDivider()
                valueRow("Compared with typing", presentation.speedValue, detail: presentation.speedDetail)
                SettingsDivider()
                valueRow("Active speech", presentation.activeValue, detail: presentation.activeDetail)
            } else {
                SettingsRow(title: "No dictations to compare yet", detail: presentation.emptyDetail) { EmptyView() }
            }
            if let notCounted = presentation.notCountedValue {
                SettingsDivider()
                valueRow("Not counted", notCounted, detail: presentation.notCountedDetail)
            }
            SettingsDivider()
            SettingsRow(
                title: "Assumed typing speed",
                detail: "An assumption, not a measurement of you. Set it to your own speed."
            ) {
                Stepper(
                    value: $viewModel.typingBaselineWPM,
                    in: SpeakingEfficiency.typingWPMRange,
                    step: 5
                ) {
                    Text(SpeakingFormat.wpm(viewModel.typingBaselineWPM))
                        .font(.callout.monospacedDigit())
                }
                .fixedSize()
                .accessibilityLabel("Assumed typing speed")
                .accessibilityValue("\(Int(viewModel.typingBaselineWPM)) words per minute")
            }
            SettingsDivider()
            SettingsDisclosureRow(title: "How it’s calculated", isExpanded: $showsMethod)
            if showsMethod {
                methodDetails
            }
        }
        .task { await viewModel.refreshSpeakingSummary() }
        // A dictation's active speech is measured just after it is saved.
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingsDidUpdateNotification)) { _ in
            Task { await viewModel.refreshSpeakingSummary() }
        }
    }

    private func valueRow(_ title: String, _ value: String, detail: String) -> some View {
        SettingsRow(title: title, detail: detail) {
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .multilineTextAlignment(.trailing)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private var methodDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SpeakingPresentation.method, id: \.self) { line in
                Text(line)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .settingsRowPadding()
    }
}

/// The main window's one-line summary; it opens the full comparison.
struct SpeakingSummaryStrip: View {
    let presentation: SpeakingPresentation
    let onOpenDetails: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let text = presentation.stripText {
            strip(text)
                .padding(.horizontal, WFSpace.md)
                .padding(.top, WFSpace.sm)
                .background(ThemePalette.contentBackground(colorScheme))
        }
    }

    /// "This month: " and what follows it, so the figures can be drawn
    /// stronger than the words that introduce them.
    static func parts(of text: String) -> (lead: String, figures: String) {
        guard let range = text.range(of: ": ") else { return ("", text) }
        return (String(text[..<range.upperBound]), String(text[range.upperBound...]))
    }

    private func strip(_ text: String) -> some View {
        let parts = Self.parts(of: text)
        return Button(action: onOpenDetails) {
            HStack(spacing: WFSpace.sm) {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                (Text(parts.lead).foregroundStyle(.secondary)
                    + Text(parts.figures).foregroundStyle(.primary).fontWeight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(WFType.meta.monospacedDigit())
            .padding(.horizontal, WFSpace.md)
            .padding(.vertical, WFSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ThemePalette.panelSurface(colorScheme),
                in: RoundedRectangle(cornerRadius: WFRadius.panel, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: WFRadius.panel, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Estimated active speech compared with typing at an assumed \(SpeakingFormat.wpm(presentation.typingWPM)); pauses and waiting for text aren’t counted. Open Settings → Dictation for the details and to change the typing speed.")
        .accessibilityLabel(text)
        .accessibilityHint("Opens the speaking versus typing details in Settings")
    }
}
