import AppKit
import FluidAudio
import KeyboardShortcuts
import SwiftUI

/// The basics: how dictation starts, what hears it, and where the text goes.
/// Everything else waits behind More options.
struct DictationSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var permissionsManager: PermissionsManager
    @State private var showsModels = false
    @State private var showsMoreOptions = false
    @State private var downloadError: String?

    private enum ShortcutChoice: Hashable {
        case modifier(ModifierKey)
        case keyCombination
        case mouseButton
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPaneHeader(
                title: "Dictation",
                subtitle: "Press a shortcut, speak, and your words appear where you’re typing."
            )
            shortcutGroup
            recordingGroup
            speechGroup
            afterDictationGroup
            moreOptions
        }
        .alert("Download failed", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
    }

    // MARK: Shortcut

    private var shortcutChoice: ShortcutChoice {
        if viewModel.mouseButtonHotkey != .none { return .mouseButton }
        if viewModel.modifierOnlyHotkey != .none { return .modifier(viewModel.modifierOnlyHotkey) }
        return .keyCombination
    }

    private var shortcutBinding: Binding<ShortcutChoice> {
        Binding(
            get: { shortcutChoice },
            set: { choice in
                switch choice {
                case .modifier(let key):
                    viewModel.mouseButtonHotkey = .none
                    viewModel.modifierOnlyHotkey = key
                    if viewModel.secondaryModifierOnlyHotkey == key {
                        viewModel.secondaryModifierOnlyHotkey = .none
                    }
                case .keyCombination:
                    viewModel.mouseButtonHotkey = .none
                    viewModel.modifierOnlyHotkey = .none
                case .mouseButton:
                    viewModel.modifierOnlyHotkey = .none
                    if viewModel.mouseButtonHotkey == .none {
                        viewModel.mouseButtonHotkey = .middle
                    }
                }
            }
        )
    }

    private var shortcutGroup: some View {
        SettingsGroup(title: "Shortcut") {
            SettingsRow(title: "Start dictation") {
                Picker("Shortcut that starts dictation", selection: shortcutBinding) {
                    Section("Modifier key") {
                        ForEach(ModifierKey.allCases.filter { $0 != .none }) { key in
                            Text(key.displayName).tag(ShortcutChoice.modifier(key))
                        }
                    }
                    Section("Other") {
                        Text("Key combination").tag(ShortcutChoice.keyCombination)
                        Text("Mouse button").tag(ShortcutChoice.mouseButton)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            switch shortcutChoice {
            case .modifier(let primary):
                SettingsDivider()
                SettingsRow(
                    title: "Second key",
                    detail: "Either key starts dictation, for example Control on a keyboard without Fn."
                ) {
                    Picker("Second key that also starts dictation", selection: $viewModel.secondaryModifierOnlyHotkey) {
                        ForEach(ModifierKey.allCases.filter { $0 != primary }) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                if permissionsManager.hasCompletedInitialCheck && !permissionsManager.isInputMonitoringPermissionGranted {
                    SettingsDivider()
                    SettingsNotice(
                        title: "Turn on Input Monitoring",
                        detail: "macOS needs it to notice \(primary.displayName) while you hold it. WorkFlow reads only modifier keys and whether another key is pressed, never what you type."
                    ) {
                        Button("Grant…") {
                            permissionsManager.requestInputMonitoringPermissionOrOpenSystemPreferences()
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Grant Input Monitoring")
                    }
                }
            case .keyCombination:
                SettingsDivider()
                SettingsRow(title: "Key combination", detail: "Works without extra permissions.") {
                    KeyboardShortcuts.Recorder("", name: .toggleRecord)
                        .fixedSize()
                        .accessibilityLabel("Record a key combination")
                }
            case .mouseButton:
                SettingsDivider()
                SettingsRow(
                    title: "Mouse button",
                    detail: "Left and right are reserved; pick the middle or a thumb button."
                ) {
                    Picker("Mouse button", selection: $viewModel.mouseButtonHotkey) {
                        ForEach(MouseButton.allCases.filter { $0 != .none }) { button in
                            Text(button.displayName).tag(button)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                if permissionsManager.hasCompletedInitialCheck && !permissionsManager.isAccessibilityPermissionGranted {
                    SettingsDivider()
                    SettingsNotice(
                        title: "Turn on Accessibility",
                        detail: "macOS needs it to use a mouse button as a shortcut. Only the selected button is intercepted."
                    ) {
                        Button("Grant…") {
                            permissionsManager.requestAccessibilityPermissionOrOpenSystemPreferences()
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Grant Accessibility")
                    }
                }
            }
        }
    }

    // MARK: Recording

    private var recordingGroup: some View {
        SettingsGroup(title: "Recording") {
            SettingsRow(
                title: viewModel.holdToRecord ? "Hold to talk" : "Tap to start and stop",
                detail: viewModel.holdToRecord
                    ? "Hold the shortcut while you speak and let go to finish. A quick tap keeps listening until you press it again."
                    : "Press the shortcut once to start and again to finish."
            ) {
                Picker("How the shortcut records", selection: $viewModel.holdToRecord) {
                    Text("Hold").tag(true)
                    Text("Tap").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityValue(viewModel.holdToRecord ? "Hold to talk" : "Tap to start and stop")
            }
        }
    }

    // MARK: Speech

    private var speechGroup: some View {
        SettingsGroup(title: "Speech") {
            SettingsRow(title: "Speech model", detail: viewModel.speechModelDetail(viewModel.currentSpeechModel)) {
                Picker("Speech model", selection: Binding(
                    get: { viewModel.currentSpeechModel },
                    set: { viewModel.useSpeechModel($0) }
                )) {
                    let options = viewModel.speechModelOptions
                    let parakeet = options.filter { if case .parakeet = $0.choice { return true } else { return false } }
                    let whisper = options.filter { if case .whisper = $0.choice { return true } else { return false } }
                    if !parakeet.isEmpty {
                        Section("Parakeet") {
                            ForEach(parakeet) { Text($0.name).tag($0.choice) }
                        }
                    }
                    if !whisper.isEmpty {
                        Section("Whisper") {
                            ForEach(whisper) { Text($0.name).tag($0.choice) }
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(viewModel.isDownloading)
            }
            SettingsDivider()
            SettingsRow(title: "Language") {
                Picker("Dictation language", selection: $viewModel.selectedLanguage) {
                    ForEach(viewModel.supportedLanguages, id: \.self) { code in
                        Text(LanguageUtil.languageNames[code] ?? code).tag(code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                SettingsDivider()
                SettingsToggleRow(
                    title: "Asian autocorrect",
                    detail: "Fixes spacing and punctuation for Chinese, Japanese, and Korean.",
                    isOn: $viewModel.useAsianAutocorrect
                )
            }
            SettingsDivider()
            SettingsDisclosureRow(
                title: "Download models",
                detail: viewModel.isDownloading
                    ? "Downloading \(viewModel.downloadingModelName ?? "a model")…"
                    : "Every model runs on this Mac.",
                isExpanded: $showsModels
            )
            if showsModels {
                ForEach(viewModel.downloadableFluidAudioModels) { model in
                    SettingsDivider()
                    modelRow(
                        name: model.name,
                        description: model.description,
                        size: model.sizeString,
                        choice: .parakeet(version: model.version),
                        isDownloaded: model.isDownloaded,
                        progress: model.downloadProgress,
                        source: nil
                    ) { download(model) }
                }
                ForEach(viewModel.downloadableModels.filter {
                    SettingsDownloadableModels.isVisible($0,
                        selectedLanguage: viewModel.selectedLanguage,
                        systemLanguage: LanguageUtil.getSystemLanguage())
                }) { model in
                    SettingsDivider()
                    modelRow(
                        name: "Whisper \(model.name)",
                        description: model.description,
                        size: model.sizeString,
                        choice: .whisper(filename: model.filename),
                        isDownloaded: model.isDownloaded,
                        progress: model.downloadProgress,
                        source: model.huggingFacePageURL
                    ) { download(model) }
                }
                SettingsDivider()
                SettingsRow(title: "Model files") {
                    HStack(spacing: WFSpace.sm) {
                        Button("Parakeet Folder") {
                            NSWorkspace.shared.open(AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent())
                        }
                        Button("Whisper Folder") {
                            NSWorkspace.shared.open(WhisperModelManager.shared.modelsDirectory)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func modelRow(
        name: String,
        description: String,
        size: String,
        choice: SpeechModelChoice,
        isDownloaded: Bool,
        progress: Double,
        source: URL?,
        download: @escaping () -> Void
    ) -> some View {
        let isDownloadingThis = viewModel.isDownloading && viewModel.downloadingModelName == nameForDownload(choice)
        return SettingsRow(title: name, detail: description) {
            if let source, let owner = huggingFaceOwner(fromPageURL: source) {
                SettingsWebLink(owner, destination: source)
                    .accessibilityLabel("\(name) on Hugging Face, by \(owner)")
            }
            if isDownloadingThis {
                HStack(spacing: WFSpace.sm) {
                    ProgressView(value: progress)
                        .frame(width: 80)
                        .accessibilityLabel("Downloading \(name)")
                        .accessibilityValue("\(Int(progress * 100)) percent")
                    Button("Cancel") { viewModel.cancelDownload() }
                        .controlSize(.small)
                }
            } else if isDownloaded {
                if viewModel.currentSpeechModel == choice {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Use") { viewModel.useSpeechModel(choice) }
                        .controlSize(.small)
                        .accessibilityLabel("Use \(name)")
                }
            } else {
                HStack(spacing: WFSpace.sm) {
                    Text(size)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Download", action: download)
                        .controlSize(.small)
                        .disabled(viewModel.isDownloading)
                        .accessibilityLabel("Download \(name), \(size)")
                }
            }
        }
    }

    private func nameForDownload(_ choice: SpeechModelChoice) -> String? {
        switch choice {
        case .parakeet(let version):
            viewModel.downloadableFluidAudioModels.first { $0.version == version }?.name
        case .whisper(let filename):
            viewModel.downloadableModels.first { $0.filename == filename }?.name
        }
    }

    /// A finished download becomes the model in use, as it always has.
    private func download(_ model: SettingsFluidAudioModel) {
        Task {
            do {
                try await viewModel.downloadFluidAudioModel(model)
                if viewModel.downloadableFluidAudioModels.first(where: { $0.version == model.version })?.isDownloaded == true {
                    viewModel.useSpeechModel(.parakeet(version: model.version))
                }
            } catch is CancellationError {
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    private func download(_ model: SettingsDownloadableModel) {
        Task {
            do {
                try await viewModel.downloadModel(model)
                if viewModel.downloadableModels.first(where: { $0.filename == model.filename })?.isDownloaded == true {
                    viewModel.useSpeechModel(.whisper(filename: model.filename))
                }
            } catch is CancellationError {
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    // MARK: After dictating

    private var afterDictationGroup: some View {
        SettingsGroup(title: "After dictating") {
            SettingsToggleRow(
                title: "Paste where you’re typing",
                detail: "Into the app that was in front when you started.",
                isOn: $viewModel.autoPasteTranscription
            )
            SettingsDivider()
            SettingsToggleRow(
                title: "Keep it on the clipboard",
                detail: clipboardDetail,
                isOn: $viewModel.autoCopyToClipboard
            )
        }
    }

    private var clipboardDetail: String {
        switch (viewModel.autoPasteTranscription, viewModel.autoCopyToClipboard) {
        case (true, true): "The newest dictation stays on the clipboard, ready to paste again."
        case (true, false): "Your previous clipboard comes back after pasting."
        case (false, true): "Dictations are copied to the clipboard, not pasted."
        case (false, false): "Dictations are saved to History only."
        }
    }

    // MARK: More options

    @ViewBuilder
    private var moreOptions: some View {
        SettingsGroup {
            SettingsDisclosureRow(
                title: "More options",
                detail: viewModel.selectedEngine == "whisper"
                    ? "Sounds, Escape, startup, History storage, and Whisper decoding."
                    : "Sounds, Escape, startup, and History storage.",
                isExpanded: $showsMoreOptions
            )
        }
        if showsMoreOptions {
            SettingsGroup(title: "While recording") {
                SettingsToggleRow(
                    title: "Play a sound when recording starts",
                    isOn: $viewModel.playSoundOnRecordStart
                )
                if case .modifier = shortcutChoice {
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Require a double tap",
                        detail: "Two quick taps start dictation, so a stray press never does.",
                        isOn: $viewModel.doublePressToTrigger
                    )
                }
                SettingsDivider()
                SettingsToggleRow(
                    title: "Ignore Esc while recording",
                    detail: "Esc can’t delete a dictation that’s still recording; finish with your shortcut.",
                    isOn: $viewModel.ignoreEscWhileRecording
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Cancel without confirmation",
                    detail: "Skip the second Esc for recordings longer than 10 seconds.",
                    isOn: $viewModel.escCancelWithoutConfirmation
                )
                .disabled(viewModel.ignoreEscWhileRecording)
                .opacity(viewModel.ignoreEscWhileRecording ? 0.5 : 1)
                SettingsDivider()
                SettingsToggleRow(
                    title: "Add a space after sentences",
                    detail: "When the text ends with punctuation.",
                    isOn: $viewModel.addSpaceAfterSentence
                )
            }
            SettingsGroup(title: "Startup") {
                SettingsToggleRow(
                    title: "Launch at login",
                    isOn: $viewModel.launchAtLogin
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Start in the menu bar",
                    detail: "Open without the main window; the menu bar icon brings it back.",
                    isOn: $viewModel.startHiddenInMenuBar
                )
            }
            SettingsGroup(title: "History storage") {
                RecordingStorageSettingsView()
            }
            if viewModel.selectedEngine == "whisper" {
                whisperOptions
            }
        }
    }

    private var whisperOptions: some View {
        SettingsGroup(title: "Whisper decoding", footer: "These apply only to Whisper models.") {
            SettingsToggleRow(title: "Show timestamps", isOn: $viewModel.showTimestamps)
            SettingsDivider()
            SettingsToggleRow(title: "Suppress blank audio", isOn: $viewModel.suppressBlankAudio)
            SettingsDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Initial prompt")
                    .font(.system(size: 13))
                TextEditor(text: $viewModel.initialPrompt)
                    .font(.callout)
                    .frame(height: 52)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    .accessibilityLabel("Initial prompt")
                Text("Optional words that guide Whisper, such as names it should expect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .settingsRowPadding()
            SettingsDivider()
            SettingsToggleRow(
                title: "Beam search",
                detail: "Can be more accurate, but slower.",
                isOn: $viewModel.useBeamSearch
            )
            if viewModel.useBeamSearch {
                SettingsDivider()
                SettingsRow(title: "Beam size") {
                    Stepper("\(viewModel.beamSize)", value: $viewModel.beamSize, in: 1...10)
                        .fixedSize()
                        .accessibilityLabel("Beam size")
                        .accessibilityValue("\(viewModel.beamSize)")
                }
            }
            SettingsDivider()
            sliderRow(title: "Temperature", detail: "Higher values vary the wording more.", value: $viewModel.temperature)
            SettingsDivider()
            sliderRow(title: "No-speech threshold", detail: "How sure Whisper must be that a pause is silence.", value: $viewModel.noSpeechThreshold)
        }
    }

    private func sliderRow(title: String, detail: String, value: Binding<Double>) -> some View {
        SettingsRow(title: title, detail: detail) {
            HStack(spacing: WFSpace.sm) {
                Slider(value: value, in: 0...1, step: 0.1)
                    .frame(width: 140)
                    .accessibilityLabel(title)
                Text(String(format: "%.1f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
        }
    }
}

/// History retention: disk use, automatic deletion, and the folder.
struct RecordingStorageSettingsView: View {
    @State private var autoDeleteEnabled = AppPreferences.shared.autoDeleteRecordingsEnabled
    @State private var retentionDays = AppPreferences.shared.autoDeleteRecordingsAfterDays
    @State private var diskUsage: Int64 = 0
    @State private var showConfirmation = false
    @State private var pendingDays = 0
    @State private var pendingCount = 0
    @State private var pendingOldestDate: Date?

    private let dayOptions = [1, 7, 14, 30, 90]

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "Recordings on disk") {
                HStack(spacing: WFSpace.sm) {
                    Text(ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(Recording.recordingsDirectory)
                    }
                    .controlSize(.small)
                }
            }
            SettingsDivider()
            SettingsRow(
                title: "Delete old recordings",
                detail: "Removes the audio and its transcript from History."
            ) {
                HStack(spacing: WFSpace.sm) {
                    Picker("Older than", selection: Binding(
                        get: { retentionDays },
                        set: { newValue in
                            if autoDeleteEnabled {
                                requestAutoDelete(days: newValue)
                            } else {
                                retentionDays = newValue
                                AppPreferences.shared.autoDeleteRecordingsAfterDays = newValue
                            }
                        }
                    )) {
                        ForEach(dayOptions, id: \.self) { days in
                            Text("After \(countLabel(days, singular: "day", plural: "days"))").tag(days)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Delete recordings older than")
                    Toggle("Delete old recordings", isOn: Binding(
                        get: { autoDeleteEnabled },
                        set: { newValue in
                            if newValue {
                                requestAutoDelete(days: retentionDays)
                            } else {
                                autoDeleteEnabled = false
                                AppPreferences.shared.autoDeleteRecordingsEnabled = false
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Automatically delete old recordings")
                }
            }
        }
        .onAppear {
            refreshDiskUsage()
        }
        .alert("Delete Old Recordings?", isPresented: $showConfirmation) {
            Button("Delete", role: .destructive) {
                confirmAutoDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(countLabel(pendingCount, singular: "recording", plural: "recordings")) with \(pendingCount == 1 ? "its transcription" : "their transcriptions") starting from \(formattedDate(pendingOldestDate)) will be deleted.")
        }
    }

    private func requestAutoDelete(days: Int) {
        Task { @MainActor in
            let result: (count: Int, oldestDate: Date?) = (try? await RecordingStore.shared.recordingsOlderThan(days: days)) ?? (count: 0, oldestDate: nil)
            if result.count > 0 {
                pendingDays = days
                pendingCount = result.count
                pendingOldestDate = result.oldestDate
                showConfirmation = true
            } else {
                applyAutoDelete(days: days)
            }
        }
    }

    private func confirmAutoDelete() {
        applyAutoDelete(days: pendingDays)
    }

    private func applyAutoDelete(days: Int) {
        retentionDays = days
        autoDeleteEnabled = true
        AppPreferences.shared.autoDeleteRecordingsAfterDays = days
        AppPreferences.shared.autoDeleteRecordingsEnabled = true
        Task { @MainActor in
            try? await RecordingStore.shared.deleteRecordings(olderThanDays: days)
            refreshDiskUsage()
        }
    }

    private func refreshDiskUsage() {
        Task.detached {
            let usage = RecordingStore.recordingsDiskUsage()
            await MainActor.run {
                diskUsage = usage
            }
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
