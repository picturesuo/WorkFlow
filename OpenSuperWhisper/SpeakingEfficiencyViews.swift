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

    var hasComparisons: Bool { !summary.allEligible.isEmpty }

    /// The main window's one line, or nil when there is nothing to compare.
    var stripText: String? {
        guard let pace = summary.allEligible.speakingWPM else { return nil }
        let speaking = "speaking \(SpeakingFormat.wpm(pace))"
        guard !summary.measured.isEmpty else {
            return "This month: \(speaking) · time saved is measured from your next dictation"
        }
        let saved = summary.measured.savedSeconds(atWPM: typingWPM).rounded()
        let comparison = saved >= 0
            ? "≈\(SpeakingFormat.duration(saved)) saved vs typing at \(SpeakingFormat.wpm(typingWPM))"
            : "≈\(SpeakingFormat.duration(saved)) slower than typing at \(SpeakingFormat.wpm(typingWPM))"
        return "This month: \(comparison) · \(speaking)"
    }

    var savedValue: String {
        guard !summary.measured.isEmpty else { return "Not measured yet" }
        return SpeakingFormat.saved(summary.measured.savedSeconds(atWPM: typingWPM))
    }

    var savedDetail: String {
        let measured = summary.measured
        guard !measured.isEmpty else {
            return "New dictations time how long their text takes to be ready, then compare that with typing."
        }
        var detail = "\(SpeakingFormat.dictations(measured.count)): recording plus measured processing took \(SpeakingFormat.duration(measured.dictationSeconds)). Typing their \(SpeakingFormat.words(measured.producedWords)) at \(SpeakingFormat.wpm(typingWPM)) would take about \(SpeakingFormat.duration(measured.typingSeconds(atWPM: typingWPM)))"
        if let speedup = measured.speedup(atWPM: typingWPM) {
            detail += ", \(SpeakingFormat.speedup(speedup)) the dictation time"
        }
        return detail + "."
    }

    var paceValue: String {
        summary.allEligible.speakingWPM.map(SpeakingFormat.wpm) ?? "—"
    }

    var paceDetail: String {
        let all = summary.allEligible
        return "\(SpeakingFormat.words(all.spokenWords)) heard in \(SpeakingFormat.duration(all.recordingSeconds)) of recording across \(SpeakingFormat.dictations(all.count)), pauses included."
    }

    /// Present only when some dictations lack measured processing time.
    var recordingOnlyValue: String? {
        let rows = summary.recordingOnly
        guard !rows.isEmpty else { return nil }
        return SpeakingFormat.saved(rows.savedSeconds(atWPM: typingWPM))
    }

    var recordingOnlyDetail: String {
        let rows = summary.recordingOnly
        return "\(SpeakingFormat.dictations(rows.count)) without measured processing, from before timing or queued while busy. This compares \(SpeakingFormat.duration(rows.recordingSeconds)) of recording alone with typing \(SpeakingFormat.words(rows.producedWords)), so it excludes processing and overstates the saving. It isn’t added to the total above."
    }

    var emptyDetail: String {
        let excluded = summary.excludedCount
        guard excluded > 0 else { return "Dictate something and the comparison appears here." }
        return "\(excluded.formatted()) History \(excluded == 1 ? "item" : "items") this month can’t be compared; see How it’s calculated."
    }

    /// Excluded rows by reason, in a stable order, zero counts left out.
    var exclusionLines: [(label: String, count: Int)] {
        SpeakingExclusion.allCases.compactMap { reason in
            guard let count = summary.exclusions[reason], count > 0 else { return nil }
            return (SpeakingFormat.exclusion(reason), count)
        }
    }

    static let method: [String] = [
        "Speaking pace is words heard ÷ recording minutes, pauses included.",
        "Typing time is the words WorkFlow produced ÷ the assumed typing speed.",
        "Time saved is typing time − (recording + measured processing). It can be negative.",
        "Totals add words and seconds across dictations before dividing; they never average each dictation’s rate.",
        "Editing afterward isn’t measured. Meetings, imported audio, failures, and items still processing are left out, and a regenerated dictation counts once, as first produced.",
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
                valueRow("Speaking pace", presentation.paceValue, detail: presentation.paceDetail)
                if let recordingOnly = presentation.recordingOnlyValue {
                    SettingsDivider()
                    valueRow("Recording-only estimate", recordingOnly, detail: presentation.recordingOnlyDetail)
                }
            } else {
                SettingsRow(title: "No dictations to compare yet", detail: presentation.emptyDetail) { EmptyView() }
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
            let exclusions = presentation.exclusionLines
            if !exclusions.isEmpty {
                Text("Left out this month")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                ForEach(exclusions, id: \.label) { line in
                    HStack {
                        Text(line.label)
                        Spacer()
                        Text(line.count.formatted()).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
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
            VStack(spacing: 0) {
                strip(text)
                WFHairline()
            }
        }
    }

    private func strip(_ text: String) -> some View {
        Button(action: onOpenDetails) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, HistoryRow.horizontalPadding)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ThemePalette.contentBackground(colorScheme))
        .help("Typing speed is an assumed \(SpeakingFormat.wpm(presentation.typingWPM)); processing is measured and editing isn’t. Open Settings → Dictation for the full calculation.")
        .accessibilityLabel(text)
        .accessibilityHint("Opens the speaking versus typing details in Settings")
    }
}
