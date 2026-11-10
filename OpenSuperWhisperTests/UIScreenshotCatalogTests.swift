import AppKit
import Combine
import GRDB
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// Opt-in screenshot catalog: every screen in every state its views expose,
/// rendered offscreen at 2x to PNG, with `index.md`, `index.json`, and
/// `not-capturable.md`, so a reviewer can critique the UI pixel by pixel and
/// compare one revision with the next.
///
/// It skips unless `WF_UI_SHOTS_OUT` (passed to xcodebuild as
/// `TEST_RUNNER_WF_UI_SHOTS_OUT`) names an output folder. Windows are never
/// shown, made key, or ordered front. Preferences start from a clean,
/// synthetic set in the test host's own domain and are restored afterwards;
/// History is a private in-memory store with invented rows; credentials come
/// from a stub; providers and the speech engine are scripted. Nothing reads
/// Keychain, touches the general pasteboard, opens the microphone, requests a
/// permission, or sends a request.
@MainActor
final class UIScreenshotCatalogTests: XCTestCase {
    private static var rows: [CatalogRow] = []
    private static var names: Set<String> = []
    private static var unreached: [CatalogUnreached] = []
    private static var quietedSharedEngine = false

    private var output: URL!
    private var suite: UserDefaults!
    private var suiteName = ""
    private var didSetUp = false
    private var savedDomain: [String: Any]?
    private var baselineDomain: [String: Any] = [:]
    private var savedMicrophones: [MicrophoneService.AudioDevice] = []
    private var savedCurrentMicrophone: MicrophoneService.AudioDevice?
    private var savedSelectedMicrophone: MicrophoneService.AudioDevice?
    private var fixtureFiles: [URL] = []
    private var sharedStoreRows: [Recording] = []
    private let schemes: [ColorScheme] = [.light, .dark]

    private var bundleID: String { Bundle.main.bundleIdentifier ?? "" }

    // MARK: - Set up

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let path = ProcessInfo.processInfo.environment["WF_UI_SHOTS_OUT"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_WF_UI_SHOTS_OUT to a folder to render the UI screenshot catalog")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Reading AppPreferences first runs its one-time migration, so the
        // clean domain below is what every render reads.
        _ = AppPreferences.shared.selectedEngine
        if !bundleID.isEmpty { savedDomain = UserDefaults.standard.persistentDomain(forName: bundleID) }
        suiteName = "UIScreenshotCatalog-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        didSetUp = true
        Self.quietSharedEngineOnce()
        seedBaseline()
        let microphones = MicrophoneService.shared
        savedMicrophones = microphones.availableMicrophones
        savedCurrentMicrophone = microphones.currentMicrophone
        savedSelectedMicrophone = microphones.selectedMicrophone
        microphones.availableMicrophones = [Catalog.microphone, Catalog.headset]
        microphones.currentMicrophone = Catalog.microphone
        InputLevelMeter.shared.reset()
    }

    override func tearDown() {
        if didSetUp {
            writeIndex()
            writeNotCapturable()
            InputLevelMeter.shared.reset()
            let microphones = MicrophoneService.shared
            microphones.availableMicrophones = savedMicrophones
            microphones.currentMicrophone = savedCurrentMicrophone
            microphones.selectedMicrophone = savedSelectedMicrophone
            for url in fixtureFiles { try? FileManager.default.removeItem(at: url) }
            fixtureFiles = []
            suite.removePersistentDomain(forName: suiteName)
            if !bundleID.isEmpty {
                if let savedDomain {
                    UserDefaults.standard.setPersistentDomain(savedDomain, forName: bundleID)
                } else {
                    UserDefaults.standard.removePersistentDomain(forName: bundleID)
                }
            }
            didSetUp = false
        }
        super.tearDown()
    }

    /// Every ContentView reaches `TranscriptionService.shared` through the file
    /// drop handler, which loads the selected speech engine. The catalog never
    /// transcribes with it, so it is created once as Whisper without a model,
    /// which fails at once instead of loading Parakeet into memory.
    private static func quietSharedEngineOnce() {
        guard !quietedSharedEngine else { return }
        quietedSharedEngine = true
        let standard = UserDefaults.standard
        let keys = ["selectedEngine", "selectedWhisperModelPath", "selectedModelPath"]
        let saved = keys.map { standard.object(forKey: $0) }
        standard.set("whisper", forKey: "selectedEngine")
        standard.removeObject(forKey: "selectedWhisperModelPath")
        standard.removeObject(forKey: "selectedModelPath")
        let service = TranscriptionService.shared
        spin(timeout: 3) { !service.isLoading }
        for (key, value) in zip(keys, saved) {
            if let value { standard.set(value, forKey: key) } else { standard.removeObject(forKey: key) }
        }
    }

    /// One synthetic set of preferences for every render: nothing the test
    /// host's domain held before, including anything migrated into it, shows.
    private func seedBaseline() {
        let standard = UserDefaults.standard
        if !bundleID.isEmpty {
            standard.setPersistentDomain(["didMigratePreferencesToWorkFlow": true], forName: bundleID)
        }
        let values: [String: Any] = [
            "hasCompletedOnboarding": true,
            "modifierOnlyHotkey": ModifierKey.leftControl.rawValue,
            "secondaryModifierOnlyHotkey": ModifierKey.fn.rawValue,
            "mouseButtonHotkey": MouseButton.none.rawValue,
            "modifierChordHotkey": ModifierChord.none.rawValue,
            "selectedEngine": "fluidaudio",
            "fluidAudioModelVersion": "v3",
            "whisperLanguage": "en",
            "holdToRecord": true,
            "autoCopyToClipboard": false,
            "autoPasteTranscription": true,
            "playSoundOnRecordStart": false,
            "reduceBackgroundAudio": false,
            "bedrockCleanupEnabled": true,
            "cleanupProviderID": CleanupProviderID.bedrock.rawValue,
            "bedrockRegion": BedrockCleanupConfiguration.defaultRegion,
            "bedrockModelID": BedrockCleanupConfiguration.defaultModelID,
            "bedrockTimeoutSeconds": 3.0,
            "bedrockMonthlyBudgetEnabled": true,
            "bedrockMonthlyBudgetUSD": 0.25,
            "launchAtLogin": false,
            "startHiddenInMenuBar": false,
            "autoDeleteRecordingsEnabled": false,
            "autoDeleteRecordingsAfterDays": 30,
            SpeakingEfficiency.typingWPMKey: 40.0,
        ]
        for (key, value) in values { standard.set(value, forKey: key) }
        VocabularyStore.save(Catalog.vocabulary)
        TargetAppRuleStore.save(Catalog.appRules)
        CustomCleanupFilterStore.select(.builtIn(.everyday))
        resetSuite()
    }

    /// The view tree's `defaultAppStorage`: dictation mode, saved filters, and Auto.
    private func resetSuite() {
        suite.removePersistentDomain(forName: suiteName)
        suite.set(ModifierKey.leftControl.rawValue, forKey: "modifierOnlyHotkey")
        CustomCleanupFilterStore.select(.builtIn(.everyday), in: suite)
    }

    private func captureBaseline() {
        guard !bundleID.isEmpty else { return }
        baselineDomain = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
    }

    private func restoreBaseline() {
        guard !bundleID.isEmpty else { return }
        UserDefaults.standard.setPersistentDomain(baselineDomain, forName: bundleID)
    }

    private func apply(_ defaults: [String: Any?]) {
        let standard = UserDefaults.standard
        for (key, value) in defaults {
            if let value { standard.set(value, forKey: key) } else { standard.removeObject(forKey: key) }
        }
    }

    // MARK: - Main window

    func testMainWindow() throws {
        let history = try Catalog.history(now: Date())
        fixtureFiles += history.audio
        for size in Catalog.mainSizes {
            for scheme in schemes {
                try windowShot(
                    "history-populated", size: size, scheme: scheme,
                    rows: history.rows, sources: history.measured, regeneratingID: history.regeneratingID,
                    note: "30 synthetic rows over 3 days, 14 with measured speech so the time-saved strip shows; one row is regenerating"
                )
                try windowShot(
                    "history-no-speaking-data", size: size, scheme: scheme,
                    rows: history.rows, regeneratingID: history.regeneratingID,
                    note: "No dictation evidence, so the time-saved strip is hidden"
                )
                try windowShot(
                    "speaking-not-measured", size: size, scheme: scheme,
                    rows: history.rows, sources: history.unmeasured, regeneratingID: history.regeneratingID,
                    view: "SpeakingSummaryStrip", note: "Evidence without measured active speech"
                )
                try windowShot("history-empty", size: size, scheme: scheme, view: "HistoryEmptyState")

                let lock = CatalogDatabaseLock()
                try windowShot(
                    "history-loading", size: size, scheme: scheme, waitForHistory: false,
                    beforeShow: { lock.hold($0) },
                    method: "The first History page is held by a database write lock",
                    prepare: { window in
                        window.host.settle(0.3, timeout: 2) { window.model.isLoadingMore }
                        return window.model.isLoadingMore && window.model.recordings.isEmpty
                    },
                    finish: { window in
                        lock.release()
                        window.host.settle(0.1, timeout: 3) { !window.model.isLoadingMore }
                    }
                )
                try windowShot(
                    "load-error-no-rows", size: size, scheme: scheme, waitForHistory: false,
                    beforeShow: { try Catalog.hideHistoryTable($0) },
                    view: "HistoryLoadError", method: "The History table is renamed so the first query fails",
                    prepare: { window in
                        window.host.settle(0.3, timeout: 3) { window.model.historyError != nil }
                        return window.model.historyError != nil
                    }
                )
                try windowShot(
                    "load-error-with-rows", size: size, scheme: scheme,
                    rows: history.rows, sources: history.measured,
                    view: "HistoryLoadError", method: "The table is renamed after the first page loaded, then History refreshes",
                    prepare: { window in
                        try Catalog.hideHistoryTable(window.database)
                        window.model.refreshHistory()
                        window.host.settle(0.3, timeout: 3) { window.model.historyError != nil }
                        return window.model.historyError != nil && !window.model.recordings.isEmpty
                    }
                )
                try windowShot(
                    "search-matches", size: size, scheme: scheme, rows: history.rows, sources: history.measured,
                    view: "TranscriptionView", method: "Typed into the toolbar search field through its delegate",
                    note: "Query “review”, highlighted in each match",
                    prepare: { window in
                        window.search("review")
                        return !window.model.recordings.isEmpty && window.model.recordings.count < history.rows.count
                    }
                )
                try windowShot(
                    "search-no-matches", size: size, scheme: scheme, rows: history.rows, sources: history.measured,
                    view: "HistoryEmptyState", method: "Typed into the toolbar search field through its delegate",
                    note: "Query “zebra”",
                    prepare: { window in
                        window.search("zebra")
                        return window.model.recordings.isEmpty
                    }
                )
                try windowShot(
                    "input-monitoring-notice", size: size, scheme: scheme,
                    rows: history.rows, sources: history.measured, regeneratingID: history.regeneratingID,
                    permissions: PermissionsManager(microphone: true, accessibility: true, inputMonitoring: false),
                    view: "InputMonitoringNotice", method: "PermissionsManager(microphone:accessibility:inputMonitoring:) with Input Monitoring off"
                )
                try windowShot(
                    "dictation-connecting", size: size, scheme: scheme, rows: history.rows, sources: history.measured,
                    view: "DictationDock", method: "ContentViewModel.state = .connecting",
                    prepare: { window in
                        window.model.state = .connecting
                        window.host.settle(0.8)
                        return true
                    }
                )
                try windowShot(
                    "dictation-listening", size: size, scheme: scheme, rows: history.rows, sources: history.measured,
                    scripted: true, view: "DictationDock",
                    method: "A scripted recorder session and synthetic input levels",
                    note: "The window's clock starts at 0:00; the dock family shows 0:07 and 12:34",
                    prepare: { window in
                        (window.model as? CatalogRecordingViewModel)?.scriptedRecording = true
                        window.model.updateRecorderState(isRecording: true, isConnecting: false)
                        Catalog.loudLevels.forEach { InputLevelMeter.shared.push($0) }
                        window.host.settle(0.8)
                        return window.model.state == .recording
                    },
                    finish: { _ in InputLevelMeter.shared.reset() }
                )
                try windowShot(
                    "dictation-transcribing", size: size, scheme: scheme, rows: history.rows, sources: history.measured,
                    view: "DictationDock", method: "ContentViewModel.state = .decoding",
                    prepare: { window in
                        window.model.state = .decoding
                        window.host.settle(0.8)
                        return true
                    }
                )
                let gate = CatalogGate()
                try windowShot(
                    "dictation-processing-queue", size: size, scheme: scheme, rows: history.rows, sources: history.measured,
                    engine: CatalogEngine(gate: gate), view: "DictationDock",
                    method: "The injected TranscriptionService is held mid-transcription by a gated engine",
                    prepare: { window in
                        let service = window.service
                        window.backgroundTask = Task {
                            _ = try? await service.transcribeAudio(url: Catalog.syntheticAudioURL, settings: OpenSuperWhisper.Settings())
                        }
                        window.host.settle(0.8, timeout: 3) { service.isTranscribing }
                        return service.isTranscribing
                    },
                    finish: { window in
                        gate.open()
                        if let task = window.backgroundTask { _ = try? self.runAsync { await task.value } }
                    }
                )
                try windowShot(
                    "no-microphone", size: size, scheme: scheme, rows: history.rows, sources: history.measured,
                    view: "DictationDock", method: "MicrophoneService.shared with no input devices",
                    prepare: { window in
                        MicrophoneService.shared.availableMicrophones = []
                        MicrophoneService.shared.currentMicrophone = nil
                        window.host.settle(0.8)
                        return true
                    },
                    finish: { _ in
                        MicrophoneService.shared.availableMicrophones = [Catalog.microphone, Catalog.headset]
                        MicrophoneService.shared.currentMicrophone = Catalog.microphone
                    }
                )
                try windowShot(
                    "file-drop-overlay", size: size, scheme: scheme, rows: history.rows, sources: history.measured,
                    view: "FileDropOverlay", method: "FileDropHandler.shared.isDragging = true, the flag a drag sets",
                    prepare: { window in
                        FileDropHandler.shared.isDragging = true
                        window.host.settle(0.6)
                        return true
                    },
                    finish: { _ in FileDropHandler.shared.isDragging = false }
                )
                try windowShot(
                    "long-transcript-expanded", size: size, scheme: scheme, rows: history.rows, sources: history.measured,
                    view: "TranscriptionView", method: "Show full text clicked with performClick",
                    prepare: { window in window.expandLongTranscript() }
                )
            }
        }

        // The toolbar alone, for the meeting states the whole window cannot reach.
        let toolbarCases: [(String, String, Bool, Bool, Bool, String)] = [
            ("idle", "", false, false, true, ""),
            ("search-text", "design review", false, false, true, ""),
            ("meeting-recording", "", true, true, true, "The stop button joins the toolbar"),
            ("meeting-saving", "", false, true, false, "The stop button is disabled while the meeting saves"),
        ]
        for (state, search, recording, inProgress, available, note) in toolbarCases {
            for width in [CGFloat(560), 440] {
                for scheme in schemes {
                    let toolbar = MainToolbar(
                        searchText: .constant(search),
                        meetingLabel: recording ? "Stop & save meeting" : "Start meeting",
                        isMeetingRecording: recording,
                        isMeetingInProgress: inProgress,
                        isMeetingAvailable: available,
                        canDeleteAll: true,
                        onMeeting: {}, onDeleteAll: {}, onSettings: {}
                    )
                    try shot(
                        toolbar, screen: "main-toolbar", state: state, scheme: scheme,
                        size: CGSize(width: width, height: WFChrome.titleBarHeight),
                        background: ThemePalette.chromeBackground(scheme), family: CatalogFamily.main,
                        view: "MainToolbar", method: "MainToolbar(searchText:meetingLabel:isMeetingRecording:isMeetingInProgress:...)",
                        note: [note, "Standalone, so the window's traffic lights are not drawn"].filter { !$0.isEmpty }.joined(separator: "; ")
                    )
                }
            }
        }
    }

    // MARK: - Permissions

    func testPermissions() throws {
        let cases: [(String, Bool, Bool)] = [
            ("microphone-missing", false, true),
            ("accessibility-missing", true, false),
            ("both-missing", false, false),
        ]
        for (state, microphone, accessibility) in cases {
            for size in [CGSize(width: 560, height: 720), CGSize(width: 440, height: 460)] {
                for scheme in schemes {
                    try windowShot(
                        state, screen: "permissions", size: size, scheme: scheme,
                        permissions: PermissionsManager(microphone: microphone, accessibility: accessibility, inputMonitoring: true),
                        waitForHistory: false, view: "PermissionsView",
                        method: "PermissionsManager(microphone:accessibility:inputMonitoring:)"
                    )
                }
            }
        }
        suite.set(true, forKey: RenamedAppMigration.didMigrateFromChatKey)
        for size in [CGSize(width: 560, height: 720), CGSize(width: 440, height: 460)] {
            for scheme in schemes {
                try windowShot(
                    "both-missing-after-rename", screen: "permissions", size: size, scheme: scheme,
                    permissions: PermissionsManager(microphone: false, accessibility: false, inputMonitoring: true),
                    waitForHistory: false, view: "PermissionsView",
                    method: "PermissionsManager(...) plus the renamed-app flag in defaultAppStorage",
                    note: "Shows the note for people who used the app under its earlier name"
                )
            }
        }
        resetSuite()
    }

    // MARK: - History rows

    func testHistoryRows() throws {
        // A fixed time of day, so two runs draw the same metadata line.
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3_600 + 41 * 60)
        let speaking = SpeakingEligibility.eligible(SpeakingSample(
            recordingSeconds: 18, activeSpeechSeconds: 12.5, spokenWords: 44, producedWords: 40, processingSeconds: 1.4
        ))
        func make(_ text: String, seconds: TimeInterval = 4, status: RecordingStatus = .completed, progress: Float = 1,
                  source: TranscriptCleanupOutcome.Source? = .disabled, tokens: (Int, Int)? = nil, model: String? = nil,
                  mode: CleanupMode? = nil, meeting: String? = nil, file: String? = nil) -> Recording {
            Catalog.recording(text, at: now, seconds: seconds, status: status, progress: progress,
                              source: source, tokens: tokens, model: model, mode: mode, meeting: meeting, file: file)
        }
        var regenerating = make("Send the revised budget to finance before Friday.", status: .transcribing, progress: 0.4,
                                source: .openAI, tokens: (190, 28), mode: .everyday)
        regenerating.isRegeneration = true
        var withSpeaking = make("Make the search faster, keep every detail, and give the words a little more room.",
                                seconds: 18, source: .bedrock, tokens: (230, 42), model: BedrockCleanupConfiguration.defaultModelID, mode: .technical)
        withSpeaking.speaking = speaking
        var autoTriggers = make("The derivative of 3x² is 6x, and the integral brings it back.", seconds: 6,
                                source: .anthropic, tokens: (300, 40), mode: .homework)
        autoTriggers.cleanupFilterName = "Calculus"
        autoTriggers.cleanupFilterReason = .triggers(["derivative", "integral"])
        var autoFallback = make("Ask the venue whether the projector supports HDMI.", source: .ollama, tokens: (120, 20), mode: .everyday)
        autoFallback.cleanupFilterReason = .fallback
        var allBadges = withSpeaking
        allBadges.cleanupFilterName = "Release notes"
        allBadges.cleanupFilterReason = .triggers(["changelog", "release"])

        let cases: [CatalogRowCase] = [
            CatalogRowCase("collapsed-long-transcript", make(Catalog.longText, seconds: 91, source: .bedrock, tokens: (980, 640), model: BedrockCleanupConfiguration.defaultModelID, mode: .writing), widths: [560, 440]),
            CatalogRowCase("expanded-long-transcript", make(Catalog.longText, seconds: 91, source: .bedrock, tokens: (980, 640), model: BedrockCleanupConfiguration.defaultModelID, mode: .writing), widths: [560, 440], expand: true),
            CatalogRowCase("short-one-line", make("Move the design review to Thursday afternoon.", seconds: 3)),
            CatalogRowCase("multi-line-short", make("A small plan\nKeep the details\nMake it clear\nLeave room to think", seconds: 9)),
            CatalogRowCase("playing", make("Remind me to water the tomatoes after work.", seconds: 4), playing: true, note: "isPlaying: true shows Stop beside Copy"),
            CatalogRowCase("failed-with-audio", make("Failed to transcribe: The speech model could not process the audio.", seconds: 12, status: .failed, progress: 0, source: nil), widths: [560, 440], note: "Regenerate is the visible action"),
            CatalogRowCase("failed-without-audio", make("Failed to transcribe: The speech model could not process the audio.", seconds: 12, status: .failed, progress: 0, source: nil), audio: false, note: "Only the actions menu remains"),
            CatalogRowCase("status-pending-import", make("In queue...", seconds: 1_820, status: .pending, progress: 0, source: nil, file: "/Users/Shared/Fixtures/Weekly sync.m4a")),
            CatalogRowCase("status-converting-import", make("", seconds: 1_820, status: .converting, progress: 0.1, source: nil, file: "/Users/Shared/Fixtures/Lecture 12.m4a")),
            CatalogRowCase("status-transcribing-40-percent", make("", seconds: 1_820, status: .transcribing, progress: 0.4, source: nil, file: "/Users/Shared/Fixtures/Lecture 12.m4a")),
            CatalogRowCase("status-regenerating", regenerating, note: "isRegeneration with status .transcribing"),
            CatalogRowCase("status-completed-no-speech", make("", seconds: 2), note: "An empty completed transcript"),
            CatalogRowCase("meeting", make("We agreed to keep the current shortcuts, make failures easy to recover from, and review the first version on Friday.", seconds: 1_820, meeting: "Planning sync"), widths: [560, 440]),
            CatalogRowCase("badge-bedrock-priced", make("Let's ship the smaller fix first and test the rest tomorrow.", source: .bedrock, tokens: (212, 31), model: BedrockCleanupConfiguration.defaultModelID, mode: .technical)),
            CatalogRowCase("badge-bedrock-tokens-unpriced", make("Add a retry with backoff to the upload client.", source: .bedrock, tokens: (198, 45), model: "us.fixture.unpriced-model-v1", mode: .technical)),
            CatalogRowCase("badge-bedrock-plain", make("Summarize the survey results in three bullet points.", source: .bedrock)),
            CatalogRowCase("badge-ollama", make("Bring the extension cord to the workshop on Sunday.", source: .ollama, tokens: (120, 18))),
            CatalogRowCase("badge-custom-api", make("Rename the export button to Save a Copy.", source: .openAICompatible, tokens: (140, 22))),
            CatalogRowCase("badge-azure-openai", make("Book the meeting room for the quarterly review.", source: .azureOpenAI, tokens: (150, 24))),
            CatalogRowCase("badge-openai", make("Reply to the landlord about the heating schedule.", source: .openAI, tokens: (160, 26))),
            CatalogRowCase("badge-anthropic", make("Order more coffee filters for the office kitchen.", source: .anthropic)),
            CatalogRowCase("badge-original-transcript", make("Check whether the train leaves at eight or at nine.", source: .rawFallback), note: "Cleanup did not finish; caution color"),
            CatalogRowCase("badge-cost-stop", make("Draft a short thank-you note to the team for staying late.", source: .budgetLimited), note: "Monthly cost stop reached; caution color"),
            CatalogRowCase("badge-cleanup-off", make("Pick up printer paper and two blue folders.", source: .disabled)),
            CatalogRowCase("badge-none-older-row", make("Call the dentist to move the cleaning to next week.", source: nil), note: "No cleanup source recorded"),
            CatalogRowCase("filter-auto-triggers", autoTriggers),
            CatalogRowCase("filter-auto-fallback", autoFallback),
            CatalogRowCase("speaking-badge", withSpeaking),
            CatalogRowCase("all-badges", allBadges, widths: [560, 440], note: "Cleanup, speaking, and Auto badges together, which wrap when narrow"),
            CatalogRowCase("search-highlight", make("Move the design review to Thursday and review the slides first.", seconds: 4), query: "review"),
        ]
        for item in cases {
            for width in item.widths {
                for scheme in schemes {
                    let row = historyRow(item.recording, query: item.query, playing: item.playing, audio: item.audio)
                    try shot(
                        row, screen: "history-row", state: item.state, scheme: scheme, width: width,
                        background: ThemePalette.contentBackground(scheme), family: CatalogFamily.rows,
                        view: item.recording.status == .completed && !item.recording.transcription.isEmpty && item.expand ? "TranscriptionView" : "HistoryRow",
                        method: item.expand ? "Show full text clicked with performClick" : "HistoryRow(recording:searchQuery:isPlaying:hasAudio:...)",
                        note: item.note, settle: item.query.isEmpty ? 0.3 : 0.6,
                        prepare: { host in item.expand ? Self.clickWideButton(in: host) : true }
                    )
                }
            }
        }

        // A day header over two rows and their separator, as the list draws them.
        for scheme in schemes {
            let group = VStack(spacing: 0) {
                HistoryDayHeader(title: "Yesterday")
                historyRow(make("Remind me to send the slides before lunch.", seconds: 3, source: .budgetLimited))
                HistoryRowSeparator()
                historyRow(make("Draft a short thank-you note to the team for staying late.", seconds: 5, source: .bedrock, tokens: (150, 40), model: BedrockCleanupConfiguration.defaultModelID, mode: .writing))
            }
            try shot(
                group, screen: "history-row", state: "day-header-and-separator", scheme: scheme, width: 560,
                background: ThemePalette.contentBackground(scheme), family: CatalogFamily.rows,
                view: "HistoryDayHeader", method: "HistoryDayHeader(title:) and HistoryRowSeparator()"
            )
        }
    }

    private func historyRow(_ recording: Recording, query: String = "", playing: Bool = false, audio: Bool = true) -> HistoryRow {
        HistoryRow(
            recording: recording, searchQuery: query, isPlaying: playing, hasAudio: audio,
            onPlay: {}, onCopy: {}, onDelete: {}, onRegenerate: {},
            onRegenerateWith: { _ in }, regenerationFilters: Catalog.threeFilters
        )
    }

    private static func clickWideButton(in host: CatalogHost) -> Bool {
        guard let toggle = host.buttons.first(where: { $0.frame.width > 40 }) else { return false }
        toggle.performClick(nil)
        host.settle(0.5)
        return true
    }

    // MARK: - Dictation dock

    func testDictationDock() throws {
        let three = Catalog.threeFilters
        let large = Catalog.largeCollection
        var cases: [CatalogDockCase] = [
            CatalogDockCase("ready", .ready, widths: [560, 440]),
            CatalogDockCase("connecting", .connecting, widths: [560, 440]),
            CatalogDockCase("recording-0-07", .recording(7), widths: [560, 440], live: true),
            CatalogDockCase("recording-12-34", .recording(754), widths: [560, 440], live: true),
            CatalogDockCase("transcribing", .transcribing, widths: [560, 440]),
            CatalogDockCase("loading-model", .loadingModel, widths: [560, 440]),
            CatalogDockCase("processing-queue", .processingQueue, widths: [560, 440]),
            CatalogDockCase("meeting-1-02-05", .meeting(3_725), widths: [560, 440], live: true),
            CatalogDockCase("saving-meeting", .savingMeeting, widths: [560, 440]),
            CatalogDockCase("no-microphone", .noMicrophone, widths: [560, 440], microphones: []),
        ]
        cases += [
            CatalogDockCase("ready-no-shortcut", .ready, shortcut: "", note: "No saved shortcut"),
            CatalogDockCase("ready-long-shortcut", .ready, widths: [560, 440], shortcut: Catalog.longShortcut, note: "A long shortcut description"),
            CatalogDockCase("recording-long-shortcut", .recording(7), widths: [440], shortcut: Catalog.longShortcut, live: true),
            CatalogDockCase("ready-three-filters", .ready, widths: [560, 440], filters: three, selection: .custom(three[0].id), note: "Saved filters turn the modes into a menu"),
            CatalogDockCase("ready-large-collection", .ready, filters: large, selection: .custom(large[3].id), note: "More than 8 filters use a pull-down with submenus"),
            CatalogDockCase("ready-auto-on", .ready, auto: true, note: "Auto without saved filters"),
            CatalogDockCase("ready-auto-on-three-filters", .ready, widths: [560, 440], filters: three, auto: true),
            CatalogDockCase("ready-auto-off-three-filters", .ready, filters: three, auto: false, note: "Auto offered but off"),
            CatalogDockCase("recording-auto-on", .recording(7), widths: [560, 440], filters: three, auto: true, live: true, note: "The detail line says Auto picks the filter after"),
            CatalogDockCase("recording-quiet-level", .recording(7), live: false, note: "Listening with a silent microphone"),
            CatalogDockCase("ready-without-learn-and-microphone-menu", .ready, learn: false, microphoneMenu: false),
            CatalogDockCase("ready-external-microphone", .ready, microphones: [Catalog.headset, Catalog.microphone], note: "An external microphone selected"),
        ]
        for item in cases {
            for width in item.widths {
                for scheme in schemes {
                    if item.live {
                        InputLevelMeter.shared.reset()
                        Catalog.loudLevels.forEach { InputLevelMeter.shared.push($0) }
                    } else {
                        InputLevelMeter.shared.reset()
                    }
                    try shot(
                        dock(item), screen: "dictation-dock", state: item.state, scheme: scheme, width: width,
                        background: ThemePalette.chromeBackground(scheme), family: CatalogFamily.dock,
                        view: "DictationDock", method: "DictationDock(status:shortcut:writingSelection:...)",
                        note: [item.note, item.live ? "Synthetic loud input levels" : ""].filter { !$0.isEmpty }.joined(separator: "; "),
                        settle: 0.8
                    )
                }
            }
        }
        InputLevelMeter.shared.reset()
    }

    private func dock(_ item: CatalogDockCase) -> DictationDock {
        let learn: (() -> Void)? = item.learn ? {} : nil
        let select: ((MicrophoneService.AudioDevice) -> Void)? = item.microphoneMenu ? { _ in } : nil
        return DictationDock(
            status: item.status,
            shortcut: item.shortcut,
            writingSelection: .constant(item.selection),
            writingAuto: item.auto.map { Binding.constant($0) },
            autoFallbackName: CleanupMode.everyday.displayName,
            customFilters: item.filters,
            writingHelp: "",
            onLearn: learn,
            microphones: item.microphones,
            currentMicrophoneID: item.microphones.first?.id,
            onSelectMicrophone: select,
            onRecord: {}
        )
    }

    // MARK: - Record button

    func testRecordButton() throws {
        let cases: [(String, RecordButtonPhase, CGFloat, Bool?, String)] = [
            ("ready", .ready, 0, nil, ""),
            ("connecting", .connecting, 0, nil, "The arc turns; this is one frame"),
            ("listening-silent", .listening, 0, nil, ""),
            ("listening-half-level", .listening, 0.5, nil, ""),
            ("listening-loud", .listening, 1, nil, ""),
            ("meeting-loud", .meeting, 1, nil, ""),
            ("working", .working, 0, nil, "The arc turns; this is one frame; disabled"),
            ("unavailable", .unavailable, 0, nil, "Disabled"),
            ("connecting-reduce-motion", .connecting, 0, true, "Steady ring instead of the arc"),
            ("working-reduce-motion", .working, 0, true, "Steady ring instead of the arc"),
            ("listening-loud-reduce-motion", .listening, 1, true, "The halo keeps one size and shows the level as strength"),
        ]
        for (state, phase, level, reduceMotion, note) in cases {
            for scheme in schemes {
                let face = RecordButtonFace(phase: phase, level: level)
                    .environment(\.reduceMotionOverride, reduceMotion)
                try shot(
                    face, screen: "record-button", state: state, scheme: scheme,
                    size: CGSize(width: WFRecordControl.size, height: WFRecordControl.size),
                    background: ThemePalette.chromeBackground(scheme), family: CatalogFamily.dock,
                    view: "RecordButtonFace",
                    method: reduceMotion == nil ? "RecordButtonFace(phase:level:)" : "RecordButtonFace(phase:level:) with reduceMotionOverride",
                    note: note
                )
            }
        }
    }

    // MARK: - Indicator capsule

    func testIndicatorCapsule() throws {
        let gate = CatalogGate()
        let cleanup = CatalogGatedCleanup(gate: gate)
        let store = try RecordingStore(
            database: try DatabaseQueue(), recordingsDirectory: Recording.recordingsDirectory,
            cancelQueuedRecording: { _ in }, stopPlayback: { _ in }
        )
        let dictationGate = LatestDictationGate()
        let model = IndicatorViewModel(
            latestDictationGate: dictationGate,
            transcriptionService: TranscriptionService(engine: CatalogEngine(text: "Catalog words for the floating capsule")),
            recordingStore: store,
            cleanupPipeline: TranscriptCleanupPipeline(
                isEnabled: { true }, providerResolver: { cleanup }, vocabularyProvider: { [] },
                appRuleProvider: { _ in nil }, bedrockBudgetProvider: { nil }, failureRecorder: { _ in }
            ),
            delivery: { _ in .savedOnly }
        )
        defer { model.cleanup() }

        let cases: [CatalogIndicatorCase] = [
            CatalogIndicatorCase("connecting", .connecting),
            CatalogIndicatorCase("recording-silent", .recording, elapsed: 7, note: "Silent microphone, clock at 0:07"),
            CatalogIndicatorCase("recording-loud", .recording, levels: Catalog.loudLevels, elapsed: 7, note: "Loud synthetic levels, clock at 0:07"),
            CatalogIndicatorCase("recording-long-clock", .recording, levels: Catalog.loudLevels, elapsed: 3_725, note: "Clock at 1:02:05"),
            CatalogIndicatorCase("recording-confirm-cancel", .recording, levels: Catalog.loudLevels, elapsed: 14, confirmCancel: true, note: "isConfirmingCancel; the amber bar counts down"),
            CatalogIndicatorCase("decoding", .decoding),
            CatalogIndicatorCase("decoding-finalizing", .decoding, finalizing: true, note: "Reached by holding a scripted cleanup provider mid-request"),
            CatalogIndicatorCase("busy", .busy),
            CatalogIndicatorCase("no-microphone", .noMicrophone),
            CatalogIndicatorCase("recording-failed", .recordingFailed),
            CatalogIndicatorCase("recording-cut-short", .recordingCutShort),
            CatalogIndicatorCase("transcription-failed", .transcriptionFailed),
            CatalogIndicatorCase("paste-failed", .pasteFailed),
            CatalogIndicatorCase("clipboard-failed", .clipboardFailed),
        ]
        let backdrops: [(String, Color)] = [("gray", Color(white: 0.5)), ("white", .white), ("near-black", Color(white: 0.06))]
        for item in cases {
            InputLevelMeter.shared.reset()
            item.levels?.forEach { InputLevelMeter.shared.push($0) }
            model.recordingStartedAt = item.elapsed.map { Date().addingTimeInterval(-$0) }
            var finishing: Task<Void, Never>?
            var audio: URL?
            if item.finalizing {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-indicator-\(UUID().uuidString).wav")
                try Data("synthetic audio".utf8).write(to: url)
                audio = url
                let generation = dictationGate.begin()
                finishing = Task {
                    await model.finishDictation(audioAt: url, generation: generation, recordingStartedAt: Date().addingTimeInterval(-6))
                }
                spin(timeout: 6) { model.isFinalizing }
            }
            model.state = item.state
            model.isConfirmingCancel = item.confirmCancel
            let reached = !item.finalizing || model.isFinalizing
            if reached {
                for scheme in schemes {
                    model.recordingStartedAt = item.elapsed.map { Date().addingTimeInterval(-$0) }
                    let width = capsuleWidth(model, scheme: scheme)
                    let panel = IndicatorWindow.windowSize(forCardWidth: width > 0 ? width : IndicatorWindow.cardSize.width)
                    let size = CGSize(width: ceil(panel.width), height: ceil(panel.height))
                    for (name, color) in backdrops {
                        // Restarted per shot, so the clock reads the same in every render.
                        model.recordingStartedAt = item.elapsed.map { Date().addingTimeInterval(-$0) }
                        try shot(
                            IndicatorWindow(viewModel: model), screen: "indicator", state: "\(item.name)-on-\(name)",
                            scheme: scheme, size: size, background: color, family: CatalogFamily.indicator,
                            view: "IndicatorWindow",
                            method: item.finalizing ? "IndicatorViewModel.finishDictation held in cleanup, then state = .decoding" : "IndicatorViewModel state set directly",
                            note: [item.note, "Panel sized to the capsule's measured width (\(Int(width.rounded())) pt) plus its padding, over a \(name) backdrop"].filter { !$0.isEmpty }.joined(separator: "; ")
                        )
                    }
                }
            } else {
                Self.unreached.append(CatalogUnreached(state: "indicator \(item.name)", view: "IndicatorWindow", why: "isFinalizing never became true"))
            }
            model.isConfirmingCancel = false
            if let finishing {
                gate.open()
                try runAsync { await finishing.value }
                let saved = (try? runAsync { try await store.fetchRecordings(limit: 20, offset: 0) }) ?? []
                for row in saved { try? FileManager.default.removeItem(at: row.url) }
            }
            if let audio { try? FileManager.default.removeItem(at: audio) }
            model.state = .idle
        }
        InputLevelMeter.shared.reset()
    }

    private func capsuleWidth(_ model: IndicatorViewModel, scheme: ColorScheme) -> CGFloat {
        var width: CGFloat = 0
        let size = IndicatorWindow.windowSize
        let host = CatalogHost(
            decorate(IndicatorWindow(viewModel: model) { width = $0 }.frame(width: size.width, height: size.height), scheme: scheme),
            size: size, scheme: scheme, titled: false
        )
        defer { host.close() }
        host.settle(0.2)
        return width
    }

    // MARK: - Settings

    func testSettingsPanes() throws {
        captureBaseline()
        for pane in SettingsPane.allCases {
            for scheme in schemes {
                for size in [CGSize(width: 720, height: 660), CGSize(width: 600, height: 560)] {
                    try settingsShot(pane, state: "default", scheme: scheme, size: size,
                                     note: size.width == 720 ? "The size Settings opens at" : "The narrowest size the layout tests use")
                }
                for width in [CGFloat(720), 600] {
                    try settingsFullShot(pane, state: "default-full", scheme: scheme, width: width)
                }
            }
        }
        for variant in settingsVariants() {
            for scheme in schemes {
                restoreBaseline()
                resetSuite()
                apply(variant.defaults)
                variant.standard?()
                variant.suite?(suite)
                try settingsFullShot(variant.pane, state: variant.state, scheme: scheme, width: 720,
                                     credentials: variant.credentials, note: variant.note)
            }
        }
        restoreBaseline()
        resetSuite()
    }

    private func settingsVariants() -> [CatalogSettingsVariant] {
        let three = Catalog.threeFilters
        let large = Catalog.largeCollection
        return [
            CatalogSettingsVariant(.dictation, "shortcut-control-fn", defaults: ["modifierChordHotkey": ModifierChord.controlFn.rawValue]),
            CatalogSettingsVariant(.dictation, "shortcut-key-combination", defaults: [
                "modifierOnlyHotkey": ModifierKey.none.rawValue, "secondaryModifierOnlyHotkey": ModifierKey.none.rawValue,
                "mouseButtonHotkey": MouseButton.none.rawValue, "modifierChordHotkey": ModifierChord.none.rawValue,
            ]),
            CatalogSettingsVariant(.dictation, "shortcut-mouse-button", defaults: ["mouseButtonHotkey": MouseButton.middle.rawValue]),
            CatalogSettingsVariant(.dictation, "tap-to-record", defaults: ["holdToRecord": false]),
            CatalogSettingsVariant(.dictation, "copy-only", defaults: ["autoPasteTranscription": false, "autoCopyToClipboard": true]),
            CatalogSettingsVariant(.dictation, "whisper-engine", defaults: ["selectedEngine": "whisper"],
                                   note: "Whisper as the engine; its decoding options sit behind More options, which only a click opens"),
            CatalogSettingsVariant(.cleanup, "cleanup-off", defaults: ["bedrockCleanupEnabled": false]),
            CatalogSettingsVariant(.cleanup, "missing-key", credentials: Catalog.credentials(bedrock: false), note: "Cleanup on without a stored Bedrock key"),
            CatalogSettingsVariant(.cleanup, "last-request-failed", defaults: [
                "bedrockLastErrorMessage": "The provider did not answer within 3 seconds.",
                "bedrockLastErrorDate": Date().addingTimeInterval(-7_200),
            ]),
            CatalogSettingsVariant(.cleanup, "three-filters", suite: { defaults in
                CustomCleanupFilterStore.save(three, to: defaults)
                CustomCleanupFilterStore.select(.custom(three[0].id), in: defaults)
            }),
            CatalogSettingsVariant(.cleanup, "large-collection", suite: { defaults in
                CustomCleanupFilterStore.save(large, to: defaults)
                CustomCleanupFilterStore.select(.custom(large[3].id), in: defaults)
            }, note: "12 saved filters, grouped by base mode"),
            CatalogSettingsVariant(.cleanup, "auto-on", suite: { defaults in
                CustomCleanupFilterStore.save(three, to: defaults)
                CustomCleanupFilterStore.select(.custom(three[0].id), in: defaults)
                FilterAutoSettings.setEnabled(true, in: defaults)
            }, note: "Auto on, with a saved filter as its fallback"),
            CatalogSettingsVariant(.personalize, "empty", defaults: ["personalVocabularyData": nil, "targetAppRulesData": nil]),
            CatalogSettingsVariant(.personalize, "learned-preferences", standard: {
                _ = LearnedPreferenceStore.merge(Catalog.learnedPreferences(.everyday), into: .everyday, in: .standard)
            }, note: "Learned preferences for Everyday"),
            CatalogSettingsVariant(.personalize, "learning-off", defaults: [LearnedPreferenceStore.enabledKey: false]),
            CatalogSettingsVariant(.providerCost, "bedrock-no-key", credentials: Catalog.credentials(bedrock: false)),
            CatalogSettingsVariant(.providerCost, "bedrock-error", defaults: [
                "bedrockLastErrorMessage": "The provider did not answer within 3 seconds.",
                "bedrockLastErrorDate": Date().addingTimeInterval(-7_200),
            ], credentials: Catalog.credentials(failing: true), note: "A Keychain status error from the credential stub and a recorded failure"),
            CatalogSettingsVariant(.providerCost, "bedrock-unpriced-model", defaults: ["bedrockModelID": "us.fixture.unpriced-model-v1"]),
            CatalogSettingsVariant(.providerCost, "cost-stop-partly-used", standard: { Catalog.recordDraftUsage(input: 400_000, output: 600_000) },
                                   note: "About $0.10 of the $0.25 stop, from synthetic filter-drafting usage"),
            CatalogSettingsVariant(.providerCost, "cost-stop-reached", standard: { Catalog.recordDraftUsage(input: 1_000_000, output: 2_000_000) },
                                   note: "About $0.32 of the $0.25 stop"),
            CatalogSettingsVariant(.providerCost, "cost-stop-off", defaults: ["bedrockMonthlyBudgetEnabled": false]),
            CatalogSettingsVariant(.providerCost, "cleanup-off", defaults: ["bedrockCleanupEnabled": false]),
            CatalogSettingsVariant(.providerCost, "ollama", defaults: [
                "cleanupProviderID": CleanupProviderID.ollama.rawValue, "ollamaModelID": "llama3.2:3b",
            ]),
            CatalogSettingsVariant(.providerCost, "openai-compatible-no-key", defaults: [
                "cleanupProviderID": CleanupProviderID.openAICompatible.rawValue,
                "openAICompatibleBaseURL": "https://api.example.com/v1", "openAICompatibleModelID": "fixture-model",
            ]),
            CatalogSettingsVariant(.providerCost, "azure-openai-stored-key", defaults: [
                "cleanupProviderID": CleanupProviderID.azureOpenAI.rawValue,
                "azureOpenAIEndpoint": "https://fixture-resource.openai.azure.com", "azureOpenAIDeployment": "fixture-deployment",
            ], credentials: Catalog.credentials(cleanup: [.azureOpenAI])),
            CatalogSettingsVariant(.providerCost, "openai-stored-key", defaults: [
                "cleanupProviderID": CleanupProviderID.openAI.rawValue,
            ], credentials: Catalog.credentials(cleanup: [.openAI])),
            CatalogSettingsVariant(.providerCost, "anthropic-no-key", defaults: [
                "cleanupProviderID": CleanupProviderID.anthropic.rawValue,
            ]),
        ]
    }

    private func settingsShot(_ pane: SettingsPane, state: String, scheme: ColorScheme, size: CGSize,
                              credentials: StoredCredentialStatus? = nil, note: String = "") throws {
        try shot(
            SettingsView(selection: .constant(pane), credentials: credentials ?? Catalog.credentials(), size: size),
            screen: "settings-\(Self.slug(pane.title))", state: state, scheme: scheme, size: size,
            background: nil, family: CatalogFamily.settings, view: Catalog.paneView(pane),
            method: "SettingsView(selection:credentials:size:) with synthetic preferences and a credential stub",
            note: note, settle: 0.6
        )
    }

    private func settingsFullShot(_ pane: SettingsPane, state: String, scheme: ColorScheme, width: CGFloat,
                                  credentials: StoredCredentialStatus? = nil, note: String = "") throws {
        let height = settingsContentHeight(pane, width: width, scheme: scheme, credentials: credentials ?? Catalog.credentials())
        try settingsShot(pane, state: state, scheme: scheme, size: CGSize(width: width, height: height),
                         credentials: credentials,
                         note: [note, "Full content height"].filter { !$0.isEmpty }.joined(separator: "; "))
    }

    /// The sheet's height with its scroll view grown to the whole pane.
    private func settingsContentHeight(_ pane: SettingsPane, width: CGFloat, scheme: ColorScheme,
                                       credentials: StoredCredentialStatus) -> CGFloat {
        let size = CGSize(width: width, height: 660)
        let host = CatalogHost(
            decorate(SettingsView(selection: .constant(pane), credentials: credentials, size: size), scheme: scheme),
            size: size, scheme: scheme, titled: false
        )
        defer { host.close() }
        host.settle(0.6)
        guard let scroll = host.allViews.compactMap({ $0 as? NSScrollView }).max(by: { $0.frame.height < $1.frame.height }),
              let document = scroll.documentView, document.frame.height > 1 else {
            return Catalog.fallbackSettingsHeight(pane)
        }
        return ceil(size.height - scroll.frame.height + document.frame.height)
    }

    // MARK: - Filters

    func testFilters() throws {
        let three = Catalog.threeFilters
        let large = Catalog.largeCollection
        let fifty = Catalog.fiftyFilters
        let largeSelected = large[3]
        let cases: [CatalogCardCase] = [
            CatalogCardCase("empty", widths: [620, 544]),
            CatalogCardCase("three-filters", widths: [620, 544], filters: three, selection: .custom(three[0].id)),
            CatalogCardCase("three-filters-auto-on", filters: three, selection: .custom(three[0].id), auto: true,
                            note: "Auto on, so no row is “In use” and its fallback says so"),
            CatalogCardCase("large-collection", filters: large, selection: .custom(largeSelected.id),
                            note: "Grouped by base mode; only the group in use starts open"),
            CatalogCardCase("large-collection-search", filters: large, selection: .custom(largeSelected.id), search: "notes",
                            note: "Query “notes” typed into the filter search field through its delegate"),
            CatalogCardCase("large-collection-search-no-match", filters: large, selection: .custom(largeSelected.id), search: "zebra"),
            CatalogCardCase("fifty-filters-limit", filters: fifty, selection: .custom(fifty[0].id),
                            note: "The 50-filter limit: New and Create are disabled"),
            CatalogCardCase("editor-new-blank", widths: [620, 544],
                            draft: CustomCleanupFilter(name: "", baseMode: .everyday, instructions: "")),
            CatalogCardCase("editor-new-from-example", draft: CustomCleanupFilterStore.examples[0]),
            CatalogCardCase("editor-new-filled", widths: [620, 544], filters: three,
                            draft: CustomCleanupFilter(name: "Lab reports", baseMode: .homework,
                                                       instructions: "Write measurements as digits with their units, and keep sample labels exactly.",
                                                       writesDigits: true, triggers: ["titration", "beaker"])),
        ]
        for item in cases {
            for width in item.widths {
                for scheme in schemes {
                    resetSuite()
                    if !item.filters.isEmpty { CustomCleanupFilterStore.save(item.filters, to: suite) }
                    if let selection = item.selection { CustomCleanupFilterStore.select(selection, in: suite) }
                    if item.auto { FilterAutoSettings.setEnabled(true, in: suite) }
                    let card = CustomCleanupFiltersCard(writingFilter: WritingFilterPreferences(), newDraft: item.draft)
                        .padding(16)
                        .settingsSurface()
                        .padding(20)
                    let method = item.draft == nil ? "CustomCleanupFiltersCard(writingFilter:)" : "CustomCleanupFiltersCard(writingFilter:newDraft:)"
                    try shot(
                        card, screen: "filters-card", state: item.state, scheme: scheme, width: width + 40,
                        background: ThemePalette.windowBackground(scheme), family: CatalogFamily.other,
                        view: "CustomCleanupFiltersCard", method: method, note: item.note, settle: 0.4,
                        prepare: { host in
                            guard let search = item.search else { return true }
                            return Self.typeText(search, intoFieldWithPrefix: "Search ", in: host)
                        }
                    )
                }
            }
        }

        let pickerCases: [(String, [CustomCleanupFilter], CleanupFilterSelection, Bool?)] = [
            ("segmented", [], .builtIn(.everyday), nil),
            ("segmented-homework", [], .builtIn(.homework), nil),
            ("menu-three-filters", three, .custom(three[0].id), false),
            ("menu-auto-on", three, .builtIn(.everyday), true),
            ("pull-down-large-collection", large, .custom(large[1].id), false),
            ("pull-down-large-collection-auto", large, .builtIn(.everyday), true),
        ]
        for (state, filters, selection, auto) in pickerCases {
            for scheme in schemes {
                let picker = HStack {
                    WritingFilterPicker(
                        selection: .constant(selection), customFilters: filters,
                        isAuto: auto.map { Binding.constant($0) }, autoFallbackName: CleanupMode.everyday.displayName
                    )
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(12)
                try shot(
                    picker, screen: "filter-picker", state: state, scheme: scheme, width: 420,
                    background: ThemePalette.chromeBackground(scheme), family: CatalogFamily.other,
                    view: "WritingFilterPicker", method: "WritingFilterPicker(selection:customFilters:isAuto:autoFallbackName:)"
                )
            }
        }
        resetSuite()
    }

    // MARK: - Filter assistant

    func testFilterAssistant() throws {
        let calculus = Catalog.threeFilters[0]
        let remote = CleanupProviderDestination(providerID: .bedrock, model: BedrockCleanupConfiguration.defaultModelID, isOnThisMac: false)
        let local = CleanupProviderDestination(providerID: .ollama, model: "llama3.2:3b", isOnThisMac: true)
        let defaults = suite!
        func session(_ target: FilterAssistantSession.Target = .new, destination: CleanupProviderDestination, chat: CatalogChat) -> FilterAssistantSession {
            FilterAssistantSession(target: target, destination: destination, chatResolver: { chat }, budgetProvider: { nil }, defaults: defaults)
        }
        func voice(loading: Bool = false, stopGate: CatalogGate? = nil) -> FilterAssistantVoiceInput {
            FilterAssistantVoiceInput(dependencies: .init(
                start: { _, _ in true },
                stop: { _ in
                    if let stopGate { await stopGate.wait() }
                    return nil
                },
                cancel: { _ in },
                transcribe: { _ in "" },
                modelLoading: Just(loading).eraseToAnyPublisher(),
                removeFile: { _ in },
                captureStopped: Empty().eraseToAnyPublisher()
            ))
        }
        func sheet(_ session: FilterAssistantSession, _ voice: FilterAssistantVoiceInput, example: Bool = false) -> FilterAssistantSheet {
            FilterAssistantSheet(session: session, voice: voice, showsExample: example, onClose: {})
        }
        let background = Color(nsColor: .windowBackgroundColor)
        let method = "FilterAssistantSheet(session:voice:showsExample:onClose:) with a scripted provider"

        for scheme in schemes {
            resetSuite()
            try withHost(sheet(session(destination: remote, chat: CatalogChat()), voice()), width: 540, scheme: scheme, background: background) { host in
                try self.recordNatural(host, screen: "filter-assistant", state: "new-idle", scheme: scheme, family: CatalogFamily.other,
                                       view: "FilterAssistantSheet", method: method, note: "Remote provider: sends only when Send is pressed")
            }
            try withHost(sheet(session(.existing(calculus), destination: local, chat: CatalogChat()), voice()), width: 540, scheme: scheme, background: background) { host in
                try self.recordNatural(host, screen: "filter-assistant", state: "improve-existing-idle", scheme: scheme, family: CatalogFamily.other,
                                       view: "FilterAssistantSheet", method: method, note: "Improving a saved filter with a provider on this Mac")
            }
            let composing = session(destination: remote, chat: CatalogChat())
            composing.request = "Write numbers as digits and use × for times."
            composing.context = "Physics 101 problem sets"
            try withHost(sheet(composing, voice()), width: 540, scheme: scheme, background: background) { host in
                try self.recordNatural(host, screen: "filter-assistant", state: "composing", scheme: scheme, family: CatalogFamily.other,
                                       view: "FilterAssistantSheet", method: method + "; request and class typed through the session")
            }
            let withExample = session(destination: remote, chat: CatalogChat())
            withExample.request = "Match this example."
            withExample.example = "A ball dropped from 20 m falls for about 2 s.\nIts speed at the ground is 19.8 m/s."
            try withHost(sheet(withExample, voice(), example: true), width: 540, scheme: scheme, background: background) { host in
                try self.recordNatural(host, screen: "filter-assistant", state: "composing-with-example", scheme: scheme, family: CatalogFamily.other,
                                       view: "FilterAssistantSheet", method: method + "; showsExample: true")
            }

            let gate = CatalogGate()
            let drafting = session(destination: remote, chat: CatalogChat(gate: gate))
            drafting.request = "Write numbers as digits and use × for times."
            drafting.context = "Physics 101 problem sets"
            try withHost(sheet(drafting, voice()), width: 540, scheme: scheme, background: background) { host in
                drafting.send()
                host.settle(0.3)
                if drafting.isGenerating {
                    try self.recordNatural(host, screen: "filter-assistant", state: "sending", scheme: scheme, family: CatalogFamily.other,
                                           view: "FilterAssistantSheet", method: method + "; Send held by a gated provider")
                } else {
                    Self.unreached.append(CatalogUnreached(state: "filter assistant sending", view: "FilterAssistantSheet", why: "send() did not start a request"))
                }
                gate.open()
                host.settle(0.4, timeout: 4) { !drafting.isGenerating }
                if drafting.proposal != nil {
                    try self.recordNatural(host, screen: "filter-assistant", state: "reply-with-proposal", scheme: scheme, family: CatalogFamily.other,
                                           view: "FilterAssistantSheet", method: method + "; the provider's reply parsed into a proposal")
                } else {
                    Self.unreached.append(CatalogUnreached(state: "filter assistant reply", view: "FilterAssistantSheet", why: drafting.errorMessage ?? "no proposal"))
                }
            }

            let failing = session(destination: remote, chat: CatalogChat(failure: URLError(.timedOut)))
            failing.request = "Write numbers as digits."
            try withHost(sheet(failing, voice()), width: 540, scheme: scheme, background: background) { host in
                failing.send()
                host.settle(0.4, timeout: 4) { !failing.isGenerating }
                try self.recordNatural(host, screen: "filter-assistant", state: "error", scheme: scheme, family: CatalogFamily.other,
                                       view: "FilterAssistantSheet", method: method + "; the provider times out")
            }

            let conflictGate = CatalogGate()
            conflictGate.open()
            let conflict = session(.existing(calculus), destination: local, chat: CatalogChat(gate: conflictGate))
            conflict.request = "Also write × for times."
            try withHost(sheet(conflict, voice()), width: 540, scheme: scheme, background: background) { host in
                conflict.send()
                host.settle(0.4, timeout: 4) { !conflict.isGenerating }
                _ = conflict.save()
                host.settle(0.3)
                try self.recordNatural(host, screen: "filter-assistant", state: "save-conflict", scheme: scheme, family: CatalogFamily.other,
                                       view: "FilterAssistantSheet", method: method + "; Save pressed while the saved filter no longer exists",
                                       note: "The filter being improved is not in the saved list, so Save offers a new filter")
            }

            let stopGate = CatalogGate()
            let listening = voice(stopGate: stopGate)
            try withHost(sheet(session(destination: local, chat: CatalogChat()), listening), width: 540, scheme: scheme, background: background) { host in
                listening.start()
                host.settle(0.3)
                try self.recordNatural(host, screen: "filter-assistant", state: "voice-recording", scheme: scheme, family: CatalogFamily.other,
                                       view: "FilterAssistantSheet", method: "FilterAssistantVoiceInput with scripted recorder dependencies; start()")
                listening.stop()
                host.settle(0.3)
                try self.recordNatural(host, screen: "filter-assistant", state: "voice-transcribing", scheme: scheme, family: CatalogFamily.other,
                                       view: "FilterAssistantSheet", method: "FilterAssistantVoiceInput; stop() held by a gated recorder")
                stopGate.open()
                host.settle(0.3, timeout: 3) { listening.state == .idle }
                try self.recordNatural(host, screen: "filter-assistant", state: "voice-error", scheme: scheme, family: CatalogFamily.other,
                                       view: "FilterAssistantSheet", method: "FilterAssistantVoiceInput; the recorder returned no audio")
            }

            let loading = voice(loading: true)
            try withHost(sheet(session(destination: local, chat: CatalogChat()), loading), width: 540, scheme: scheme, background: background) { host in
                host.settle(0.3, timeout: 2) { loading.isModelLoading }
                try self.recordNatural(host, screen: "filter-assistant", state: "voice-model-loading", scheme: scheme, family: CatalogFamily.other,
                                       view: "FilterAssistantSheet", method: "FilterAssistantVoiceInput with modelLoading publishing true")
            }
        }
        resetSuite()
    }

    // MARK: - Correction learning

    func testCorrectionLearning() throws {
        let defaults = suite!
        let local = CleanupProviderDestination(providerID: .ollama, model: "llama3.2:3b", isOnThisMac: true)
        let remote = CleanupProviderDestination(providerID: .bedrock, model: BedrockCleanupConfiguration.defaultModelID, isOnThisMac: false)
        func session(remote isRemote: Bool = false, mode: CleanupMode = .everyday,
                     candidates: @escaping () async throws -> [CorrectionCandidate] = { [] },
                     chat: CatalogChat = CatalogChat(respond: Catalog.learningReply)) -> CorrectionLearningSession {
            CorrectionLearningSession(
                mode: mode, destination: isRemote ? remote : local, chatResolver: { chat }, budgetProvider: { nil },
                candidateProvider: candidates, defaults: defaults
            )
        }
        func card(_ session: CorrectionLearningSession) -> AnyView {
            AnyView(
                CorrectionLearningCard(session: session, defaults: defaults)
                    .padding(16)
                    .settingsSurface()
                    .padding(20)
            )
        }
        let method = "CorrectionLearningCard(session:defaults:) with scripted History candidates and provider"
        // A fixed name in a folder of its own, so the rendered summary is the same every run.
        let textFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UIScreenshotCatalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: textFolder, withIntermediateDirectories: true)
        let textFile = textFolder.appendingPathComponent("catalog-finished-document.txt")
        try Catalog.learningDocument.write(to: textFile, atomically: true, encoding: .utf8)
        fixtureFiles.append(textFolder)

        for scheme in schemes {
            let background = ThemePalette.windowBackground(scheme)
            func capture(_ state: String, _ host: CatalogHost, how: String? = nil, note: String = "") throws {
                try recordNatural(host, screen: "correction-learning", state: state, scheme: scheme, family: CatalogFamily.other,
                                  view: "CorrectionLearningCard", method: how ?? method, note: note)
            }

            resetSuite()
            try withHost(card(session(remote: true)), width: 660, scheme: scheme, background: background) { host in
                try capture("idle-empty", host, note: "Remote provider named in the disclosure")
            }

            resetSuite()
            let pasted = session()
            pasted.document = Catalog.learningDocument
            try withHost(card(pasted), width: 660, scheme: scheme, background: background) { host in
                try capture("document-pasted", host)
            }

            resetSuite()
            let loaded = session()
            try withHost(card(loaded), width: 660, scheme: scheme, background: background) { host in
                loaded.load([textFile])
                host.settle(0.3, timeout: 4) { !loaded.isLoadingFile }
                try capture("file-loaded", host, how: method + "; load(_:) with a synthetic text file")
            }

            resetSuite()
            let historyGate = CatalogGate()
            let checking = session(mode: .writing, candidates: {
                await historyGate.wait()
                return Catalog.learningCandidates()
            })
            checking.document = Catalog.learningDocument
            try withHost(card(checking), width: 660, scheme: scheme, background: background) { host in
                checking.check()
                host.settle(0.3)
                try capture("checking", host, how: method + "; check() held while History is read")
                historyGate.open()
                host.settle(0.4, timeout: 5) { !checking.isBusy }
                try capture("check-results", host, how: method + "; check() finished",
                            note: "Report status: \(checking.report.map { "\($0.status)" } ?? checking.errorMessage ?? "none")")
            }

            resetSuite()
            let providerGate = CatalogGate()
            let learning = session(mode: .writing, candidates: { Catalog.learningCandidates() },
                                   chat: CatalogChat(gate: providerGate, respond: Catalog.learningReply))
            learning.document = Catalog.learningDocument
            try withHost(card(learning), width: 660, scheme: scheme, background: background) { host in
                learning.learn()
                host.settle(0.4)
                try capture("learning", host, how: method + "; learn() held at the provider")
                providerGate.open()
                host.settle(0.4, timeout: 5) { !learning.isBusy }
                try capture("learned", host, how: method + "; learn() finished",
                            note: "Report status: \(learning.report.map { "\($0.status)" } ?? learning.errorMessage ?? "none")")
            }

            resetSuite()
            let unmatched = session(mode: .writing, candidates: { Catalog.learningCandidates() })
            unmatched.document = "Completely different words about cooking dinner tonight with friends and family at home after the long week."
            try withHost(card(unmatched), width: 660, scheme: scheme, background: background) { host in
                unmatched.check()
                host.settle(0.4, timeout: 5) { !unmatched.isBusy }
                try capture("no-matches", host)
            }

            resetSuite()
            let failing = session(candidates: { throw CatalogError() })
            failing.document = Catalog.learningDocument
            try withHost(card(failing), width: 660, scheme: scheme, background: background) { host in
                failing.check()
                host.settle(0.4, timeout: 5) { !failing.isBusy }
                try capture("error", host, how: method + "; History could not be read")
            }

            resetSuite()
            defaults.set(false, forKey: LearnedPreferenceStore.enabledKey)
            try withHost(card(session()), width: 660, scheme: scheme, background: background) { host in
                try capture("learning-off", host, how: method + "; learning switched off in defaults")
            }

            resetSuite()
            CustomCleanupFilterStore.select(.builtIn(.writing), in: defaults)
            _ = LearnedPreferenceStore.merge(Catalog.learnedPreferences(.writing), into: .writing, in: defaults)
            try withHost(card(session(mode: .writing)), width: 660, scheme: scheme, background: background) { host in
                try capture("learned-preferences-list", host, how: method + "; learned preferences seeded in defaults",
                            note: "Applied, switched off, and not-applied preferences for Writing")
            }

            resetSuite()
            let tooLong = session()
            tooLong.document = String(repeating: "Finished words. ", count: 6_400)
            try withHost(card(tooLong), width: 660, scheme: scheme, background: background) { host in
                try capture("document-too-long", host, note: "More characters than Learn accepts")
            }
        }
        resetSuite()
    }

    // MARK: - Speaking summary

    func testSpeakingSummary() throws {
        defer { clearSharedStore() }
        try speakingPhases()
    }

    private func speakingPhases() throws {
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        captureBaseline()

        // Measured dictations, older unmeasured ones, and a meeting.
        try seedSharedStore(Catalog.speakingRows(measured: 12, unmeasured: 3, meetings: 1))
        let summary = try runAsync { try await RecordingStore.shared.speakingSummary(since: monthStart) }
        try speakingShots("with-data", summary: summary, typingWPM: 40)
        UserDefaults.standard.set(65.0, forKey: SpeakingEfficiency.typingWPMKey)
        try speakingShots("typing-65-wpm", summary: summary, typingWPM: 65)
        restoreBaseline()
        for scheme in schemes {
            try settingsFullShot(.dictation, state: "speaking-data", scheme: scheme, width: 720,
                                 note: "This month's speaking-versus-typing totals from synthetic History")
        }

        // Only rows that cannot be compared.
        clearSharedStore()
        try seedSharedStore(Catalog.speakingRows(measured: 0, unmeasured: 3, meetings: 1))
        let unmeasured = try runAsync { try await RecordingStore.shared.speakingSummary(since: monthStart) }
        try speakingShots("not-measured-only", summary: unmeasured, typingWPM: 40)

        // Speaking slower than typing.
        clearSharedStore()
        try seedSharedStore(Catalog.speakingRows(measured: 0, unmeasured: 0, meetings: 0, slow: 4))
        let slow = try runAsync { try await RecordingStore.shared.speakingSummary(since: monthStart) }
        try speakingShots("slower-than-typing", summary: slow, typingWPM: 40)

        // Nothing this month.
        clearSharedStore()
        for scheme in schemes {
            for width in [CGFloat(660), 584] {
                try speakingGroupShot("no-data", scheme: scheme, width: width)
            }
        }
    }

    private func speakingShots(_ state: String, summary: SpeakingSummary, typingWPM: Double) throws {
        let presentation = SpeakingPresentation(summary: summary, typingWPM: typingWPM)
        for scheme in schemes {
            if presentation.stripText != nil {
                for width in [CGFloat(560), 440] {
                    try shot(
                        VStack(spacing: 0) { SpeakingSummaryStrip(presentation: presentation) {} },
                        screen: "speaking-strip", state: state, scheme: scheme, width: width,
                        background: ThemePalette.contentBackground(scheme), family: CatalogFamily.other,
                        view: "SpeakingSummaryStrip", method: "SpeakingSummaryStrip(presentation:onOpenDetails:) from a synthetic store's summary"
                    )
                }
            }
            for width in [CGFloat(660), 584] {
                try speakingGroupShot(state, scheme: scheme, width: width)
            }
        }
    }

    private func speakingGroupShot(_ state: String, scheme: ColorScheme, width: CGFloat) throws {
        let model = SettingsViewModel(credentials: Catalog.credentials())
        try shot(
            SpeakingSettingsGroup(viewModel: model).padding(20),
            screen: "speaking-settings", state: state, scheme: scheme, width: width,
            background: ThemePalette.windowBackground(scheme), family: CatalogFamily.other,
            view: "SpeakingSettingsGroup",
            method: "SpeakingSettingsGroup(viewModel:) reading synthetic rows from the in-memory shared store", settle: 0.6
        )
    }

    private func seedSharedStore(_ rows: [(Recording, DictationSource?)]) throws {
        sharedStoreRows += rows.map { $0.0 }
        try runAsync {
            for (recording, source) in rows {
                if let source {
                    try await RecordingStore.shared.addRecordingSync(recording, source: source)
                } else {
                    try await RecordingStore.shared.addRecordingSync(recording)
                }
            }
        }
    }

    private func clearSharedStore() {
        let rows = sharedStoreRows
        sharedStoreRows = []
        guard !rows.isEmpty else { return }
        _ = try? runAsync {
            for recording in rows {
                try? await RecordingStore.shared.deleteRecordingSync(recording)
            }
        }
    }

    // MARK: - Onboarding

    func testOnboarding() throws {
        let cases: [(String, Bool, ModifierKey, String)] = [
            ("shortcut-option-tilde", false, .none, "First run: the key combination is preselected"),
            ("shortcut-fn", true, .fn, "Fn chosen earlier; the Input Monitoring row reads this Mac's real status"),
            ("shortcut-right-option", true, .rightOption, "Right Option chosen earlier"),
        ]
        for (state, completed, key, note) in cases {
            for size in Catalog.onboardingSizes.map({ $0.size }) {
                for scheme in schemes {
                    let standard = UserDefaults.standard
                    standard.set(completed, forKey: "hasCompletedOnboarding")
                    standard.set(key.rawValue, forKey: "modifierOnlyHotkey")
                    standard.set("en", forKey: "whisperLanguage")
                    try shot(
                        OnboardingView().environmentObject(AppState()),
                        screen: "onboarding", state: state, scheme: scheme, size: size, background: nil,
                        family: CatalogFamily.other, view: "OnboardingView",
                        method: "OnboardingView() in a hidden-title-bar window; the shortcut is seeded through preferences",
                        note: note + "; " + (Catalog.onboardingSizes.first { $0.size == size }?.label ?? ""),
                        titled: true, settle: 0.9
                    )
                }
            }
        }
        seedBaseline()
    }

    // MARK: - Rendering

    private func decorate<V: View>(_ view: V, scheme: ColorScheme) -> some View {
        view
            .tint(ThemePalette.controlTint)
            .environment(\.colorScheme, scheme)
            .environment(\.appearsActive, true)
            .defaultAppStorage(suite)
    }

    /// Renders at a fixed size in points.
    private func shot<V: View>(_ content: V, screen: String, state: String, scheme: ColorScheme, size: CGSize,
                               background: Color?, family: String, view: String, method: String = "initializer",
                               note: String = "", titled: Bool = false, settle: TimeInterval = 0.3,
                               prepare: ((CatalogHost) -> Bool)? = nil) throws {
        // A titled window lays its content out below the title bar, as the
        // app's window does, so the content fills the window instead of a fixed frame.
        let root = decorate(
            content
                .frame(width: titled ? nil : size.width, height: titled ? nil : size.height)
                .frame(maxWidth: titled ? .infinity : nil, maxHeight: titled ? .infinity : nil)
                .background(background ?? Color.clear),
            scheme: scheme
        )
        let host = CatalogHost(root, size: size, scheme: scheme, titled: titled)
        defer { host.close() }
        host.settle(settle)
        if let prepare, !prepare(host) {
            Self.unreached.append(CatalogUnreached(state: "\(screen) \(state)", view: view, why: "The control that reaches it was not found offscreen"))
            return
        }
        try record(host, screen: screen, state: state, scheme: scheme, family: family, view: view, method: method, note: note,
                   requested: size)
    }

    /// Renders at a fixed width and the content's own height.
    private func shot<V: View>(_ content: V, screen: String, state: String, scheme: ColorScheme, width: CGFloat,
                               background: Color, family: String, view: String, method: String = "initializer",
                               note: String = "", settle: TimeInterval = 0.3,
                               prepare: ((CatalogHost) -> Bool)? = nil) throws {
        let root = decorate(content.frame(width: width).background(background), scheme: scheme)
        let host = CatalogHost(root, size: CGSize(width: width, height: 300), scheme: scheme, titled: false)
        defer { host.close() }
        host.settle(settle)
        if let prepare, !prepare(host) {
            Self.unreached.append(CatalogUnreached(state: "\(screen) \(state)", view: view, why: "The control that reaches it was not found offscreen"))
            return
        }
        try recordNatural(host, screen: screen, state: state, scheme: scheme, family: family, view: view, method: method, note: note)
    }

    /// Hosts content at a fixed width for several states in sequence.
    private func withHost<V: View>(_ content: V, width: CGFloat, scheme: ColorScheme, background: Color,
                                   settle: TimeInterval = 0.4, _ body: (CatalogHost) throws -> Void) throws {
        let root = decorate(content.frame(width: width).background(background), scheme: scheme)
        let host = CatalogHost(root, size: CGSize(width: width, height: 300), scheme: scheme, titled: false)
        defer { host.close() }
        host.settle(settle)
        try body(host)
    }

    /// Runs async work from a synchronous test while the main run loop keeps
    /// serving main-actor work, the way the views' own tasks run in the app.
    private func runAsync<T>(timeout: TimeInterval = 60, _ body: @escaping () async throws -> T) throws -> T {
        let box = CatalogResultBox<T>()
        Task { @MainActor in
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        }
        spin(timeout: timeout) { box.result != nil }
        guard let result = box.result else { throw CatalogError(message: "Timed out waiting for async work") }
        return try result.get()
    }

    private func recordNatural(_ host: CatalogHost, screen: String, state: String, scheme: ColorScheme, family: String,
                               view: String, method: String, note: String = "") throws {
        host.fitHeight()
        host.settle(0.15)
        host.fitHeight()
        try record(host, screen: screen, state: state, scheme: scheme, family: family, view: view, method: method, note: note)
    }

    private func windowShot(_ state: String, screen: String = "main-window", size: CGSize, scheme: ColorScheme,
                            rows: [Recording] = [], sources: [DictationSource] = [], regeneratingID: UUID? = nil,
                            permissions: PermissionsManager? = nil, engine: CatalogEngine = CatalogEngine(),
                            scripted: Bool = false, waitForHistory: Bool = true,
                            beforeShow: ((DatabaseQueue) throws -> Void)? = nil,
                            view: String = "ContentView", method: String = "ContentView(viewModel:permissionsManager:) over an in-memory store",
                            note: String = "",
                            prepare: ((CatalogWindow) throws -> Bool)? = nil,
                            finish: ((CatalogWindow) -> Void)? = nil) throws {
        let (database, store) = try CatalogWindow.makeStore()
        // Written straight to the private database, as the store's own insert
        // does, so no History-changed notification reaches another window.
        try database.write { db in
            for row in rows {
                try row.insert(db)
                try sources.first(where: { $0.recordingID == row.id })?.insert(db)
            }
        }
        try beforeShow?(database)
        let window = CatalogWindow.make(
            database: database, store: store, rowCount: rows.count, size: size, scheme: scheme, suite: suite,
            permissions: permissions, engine: engine, scripted: scripted, waitForHistory: waitForHistory,
            regeneratingID: regeneratingID
        )
        defer { window.close() }
        do {
            var reached = true
            if let prepare { reached = try prepare(window) }
            if reached {
                try record(window.host, screen: screen, state: state, scheme: scheme, family: CatalogFamily.main,
                           view: view, method: method, note: note, requested: size)
            } else {
                Self.unreached.append(CatalogUnreached(state: "\(screen) \(state) \(Int(size.width))x\(Int(size.height))", view: view,
                                                       why: "The window did not reach the state offscreen"))
            }
        } catch {
            finish?(window)
            throw error
        }
        finish?(window)
    }

    private func record(_ host: CatalogHost, screen: String, state: String, scheme: ColorScheme, family: String,
                        view: String, method: String, note: String, requested: CGSize? = nil) throws {
        let size = host.hosting.bounds.size
        var note = note
        if let requested, abs(requested.width - size.width) > 0.5 || abs(requested.height - size.height) > 0.5 {
            let grew = "Requested \(Int(requested.width))x\(Int(requested.height)) pt; the content's own minimum size made the window \(Int(size.width.rounded()))x\(Int(size.height.rounded())) pt"
            note = note.isEmpty ? grew : note + "; " + grew
        }
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        let name = "\(Self.slug(screen))__\(Self.slug(state))__\(Self.schemeName(scheme))__\(width)x\(height).png"
        let bitmap = try XCTUnwrap(host.capture(), "No bitmap for \(name)")
        let srgb = bitmap.converting(to: .sRGB, renderingIntent: .default) ?? bitmap
        let data = try XCTUnwrap(srgb.representation(using: .png, properties: [:]), "PNG encoding failed for \(name)")
        XCTAssertFalse(host.window.isVisible, "\(name): renders stay offscreen")
        XCTAssertFalse(NSApp.keyWindow === host.window || NSApp.mainWindow === host.window, "\(name): renders never take focus")
        XCTAssertEqual(srgb.pixelsWide, width * 2, "\(name) is 2x")
        XCTAssertEqual(srgb.pixelsHigh, height * 2, "\(name) is 2x")
        XCTAssertTrue(Self.hasDetail(srgb), "\(name) is a single flat color")
        let isNew = Self.names.insert(name).inserted
        XCTAssertTrue(isNew, "\(name) was rendered twice")
        try data.write(to: output.appendingPathComponent(name))
        Self.rows.append(CatalogRow(
            file: name, family: family, screen: screen, state: state, scheme: Self.schemeName(scheme),
            width: width, height: height, pixelWidth: srgb.pixelsWide, pixelHeight: srgb.pixelsHigh,
            viewType: view, source: CatalogSource.declaration(of: view), method: method, note: note,
            backingScale: Double(host.window.backingScaleFactor),
            animated: Self.drawsWallClockAnimation(screen: screen, state: state)
        ))
    }

    /// States that draw one frame of an animation driven by the wall clock,
    /// so two runs differ there and only there: the record control's progress
    /// arc while connecting or working, the indicator's processing wave while
    /// transcribing or refining, and the cancel countdown bar.
    static func drawsWallClockAnimation(screen: String, state: String) -> Bool {
        switch screen {
        case "record-button":
            // Reduce Motion replaces the arc with a steady ring.
            return ["connecting", "working"].contains(state)
        case "dictation-dock":
            // Statuses whose record control is connecting or working.
            return ["connecting", "transcribing", "loading-model", "processing-queue", "saving-meeting"].contains(state)
        case "main-window":
            return ["dictation-connecting", "dictation-transcribing", "dictation-processing-queue"].contains(state)
        case "indicator":
            return state.hasPrefix("decoding-") || state.hasPrefix("recording-confirm-cancel-")
        default:
            return false
        }
    }

    /// Types into a SwiftUI text field the way AppKit reports typing.
    private static func typeText(_ text: String, intoFieldWithPrefix prefix: String, in host: CatalogHost) -> Bool {
        guard let field = host.allViews.compactMap({ $0 as? NSTextField })
            .first(where: { $0.isEditable && ($0.placeholderString ?? "").hasPrefix(prefix) }) else { return false }
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        host.settle(0.5)
        return true
    }

    static func slug(_ text: String) -> String {
        var result = ""
        var pendingHyphen = false
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen, !result.isEmpty { result.append("-") }
                pendingHyphen = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        return result
    }

    private static func schemeName(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }

    /// At least two distinct pixel values.
    private static func hasDetail(_ bitmap: NSBitmapImageRep) -> Bool {
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }
        if let data = bitmap.bitmapData, !bitmap.isPlanar, bitmap.bitsPerPixel % 8 == 0 {
            let bytesPerPixel = bitmap.bitsPerPixel / 8
            let first = Array(UnsafeBufferPointer(start: data, count: bytesPerPixel))
            for y in 0..<bitmap.pixelsHigh {
                let row = data + y * bitmap.bytesPerRow
                for x in 0..<bitmap.pixelsWide {
                    let pixel = row + x * bytesPerPixel
                    for byte in 0..<bytesPerPixel where pixel[byte] != first[byte] { return true }
                }
            }
            return false
        }
        let first = bitmap.colorAt(x: 0, y: 0)
        let stepX = max(1, bitmap.pixelsWide / 300)
        let stepY = max(1, bitmap.pixelsHigh / 300)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) where bitmap.colorAt(x: x, y: y) != first {
                return true
            }
        }
        return false
    }

    // MARK: - Index

    private func writeIndex() {
        let jsonURL = output.appendingPathComponent("index.json")
        var merged: [String: CatalogRow] = [:]
        if let data = try? Data(contentsOf: jsonURL),
           let existing = try? JSONDecoder().decode([CatalogRow].self, from: data) {
            for row in existing where FileManager.default.fileExists(atPath: output.appendingPathComponent(row.file).path) {
                merged[row.file] = row
            }
        }
        for row in Self.rows { merged[row.file] = row }
        let order = Dictionary(uniqueKeysWithValues: CatalogFamily.order.enumerated().map { ($1, $0) })
        let all = merged.values.sorted {
            (order[$0.family] ?? 99, $0.screen, $0.state, $0.width, $0.height, $0.scheme)
                < (order[$1.family] ?? 99, $1.screen, $1.state, $1.width, $1.height, $1.scheme)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(all) { try? data.write(to: jsonURL) }

        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        let scales = Set(all.map { String(format: "%.0f", $0.backingScale) }).sorted().joined(separator: ", ")
        var markdown = """
        # WorkFlow UI screenshot catalog

        Rendered offscreen by `OpenSuperWhisperTests/UIScreenshotCatalogTests.swift`. \(all.count) images, every one from synthetic data. \
        Sizes are in points; each PNG is 2x (pixels are twice the points), sRGB. Offscreen window backing scale: \(scales). \
        SwiftUI content is told it appears active (`appearsActive`), so it draws the front-window look; AppKit-drawn pieces \
        (traffic lights, segmented controls, pop-up buttons, switches) keep their inactive look because no window is ever \
        ordered in or made key. Hover, pressed, and focus-ring states are not drawn (see `not-capturable.md`).

        Run it again with `TEST_RUNNER_WF_UI_SHOTS_OUT=<folder>` and the xcodebuild test command for \
        `-only-testing:OpenSuperWhisperTests/UIScreenshotCatalogTests`; file names stay the same, so two folders can be compared file by file. \
        Rows marked animated draw one frame of a wall-clock animation, so they differ between runs and are compared by eye.

        """
        for family in CatalogFamily.order {
            let rows = all.filter { $0.family == family }
            guard !rows.isEmpty else { continue }
            markdown += "\n## \(family) (\(rows.count))\n\n"
            markdown += "| File | Screen | State | Scheme | Size (pt) | Animated | View | Source | How reached | Note |\n"
            markdown += "|---|---|---|---|---|---|---|---|---|---|\n"
            for row in rows {
                markdown += "| \(cell(row.file)) | \(cell(row.screen)) | \(cell(row.state)) | \(row.scheme) | \(row.width)x\(row.height) | \(row.animated ? "yes" : "no") | `\(cell(row.viewType))` | `\(cell(row.source))` | \(cell(row.method)) | \(cell(row.note)) |\n"
            }
        }
        try? markdown.write(to: output.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }

    private func writeNotCapturable() {
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|") }
        var markdown = """
        # States the catalog does not capture

        Each state below is either a private `@State` that only real pointer, keyboard, or drag input sets, state owned by a \
        shared service that only real hardware or the network moves, or UI that opens its own visible window. None was faked; \
        where a nearby seam exists, the catalog renders that instead, as the Why column says.

        | State | View | Source | Why |
        |---|---|---|---|

        """
        for item in CatalogNotCapturable.all {
            markdown += "| \(cell(item.state)) | `\(cell(item.view))` | `\(CatalogSource.line(item.file, item.needle))` | \(cell(item.why)) |\n"
        }
        if !Self.unreached.isEmpty {
            markdown += "\n## Attempted in this run, not reached\n\n| State | View | Why |\n|---|---|---|\n"
            for item in Self.unreached {
                markdown += "| \(cell(item.state)) | `\(cell(item.view))` | \(cell(item.why)) |\n"
            }
        }
        try? markdown.write(to: output.appendingPathComponent("not-capturable.md"), atomically: true, encoding: .utf8)
    }
}

// MARK: - Offscreen hosts

/// One SwiftUI tree in a window that is never ordered in, on a Retina screen
/// when there is one so the backing store is 2x.
@MainActor
private final class CatalogHost {
    static let retinaScreen: NSScreen? = NSScreen.screens.first { $0.backingScaleFactor >= 2 }

    let window: NSWindow
    let hosting: NSView
    private let titled: Bool

    init<V: View>(_ root: V, size: CGSize, scheme: ColorScheme, titled: Bool) {
        let style: NSWindow.StyleMask = titled
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.borderless]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false, screen: CatalogHost.retinaScreen)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        if titled {
            // The app's hidden title bar; the content fills the whole frame,
            // so the frame is the requested size.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setFrame(NSRect(origin: .zero, size: size), display: false)
        }
        let view = NSHostingView(rootView: root)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        self.window = window
        self.hosting = view
        self.titled = titled
        view.layoutSubtreeIfNeeded()
    }

    func settle(_ seconds: TimeInterval = 0.3, timeout: TimeInterval = 4, until condition: () -> Bool = { true }) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            hosting.layoutSubtreeIfNeeded()
        } while !condition() && Date() < deadline
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        hosting.layoutSubtreeIfNeeded()
    }

    func resize(_ size: CGSize) {
        if titled {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        } else {
            window.setContentSize(size)
        }
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
    }

    func fitHeight() {
        hosting.layoutSubtreeIfNeeded()
        let height = max(1, ceil(hosting.fittingSize.height))
        if abs(height - hosting.bounds.height) > 0.5 {
            resize(CGSize(width: hosting.bounds.width, height: height))
        }
    }

    func close() {
        window.contentView = nil
        window.close()
        // Let SwiftUI tear the tree down before the next window appears.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    var allViews: [NSView] { Self.descendants(of: hosting) }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    /// Borderless SwiftUI buttons, which AppKit backs with real buttons.
    var buttons: [NSButton] {
        allViews.compactMap { $0 as? NSButton }
            .filter { !($0 is NSPopUpButton) && String(describing: type(of: $0)).contains("SwiftUI") }
    }

    func frameInHost(_ view: NSView) -> CGRect {
        let frame = view.convert(view.bounds, to: hosting)
        return hosting.isFlipped ? frame : CGRect(x: frame.minX, y: hosting.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The hosting view at 2x, plus the traffic lights of a titled window,
    /// which live in the title bar rather than in the content.
    func capture() -> NSBitmapImageRep? {
        hosting.layoutSubtreeIfNeeded()
        let bounds = hosting.bounds
        let pixelsWide = Int((bounds.width * 2).rounded())
        let pixelsHigh = Int((bounds.height * 2).rounded())
        var bitmap = hosting.bitmapImageRepForCachingDisplay(in: bounds)
        if bitmap?.pixelsWide != pixelsWide || bitmap?.pixelsHigh != pixelsHigh,
           let manual = NSBitmapImageRep(
               bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
               bytesPerRow: 0, bitsPerPixel: 0
           ) {
            // No Retina screen: draw the same points into a 2x bitmap.
            manual.size = bounds.size
            bitmap = manual
        }
        guard let bitmap else { return nil }
        hosting.cacheDisplay(in: bounds, to: bitmap)
        if titled { drawTrafficLights(into: bitmap) }
        return bitmap
    }

    private func drawTrafficLights(into bitmap: NSBitmapImageRep) {
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let cg = context.cgContext
        let scale = CGFloat(bitmap.pixelsWide) / max(bitmap.size.width, 1)
        if abs(cg.ctm.a - 1) < 0.01, scale > 1.01 { cg.scaleBy(x: scale, y: scale) }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), let layer = button.layer else { continue }
            button.display()
            let frame = button.convert(button.bounds, to: nil)
            cg.saveGState()
            cg.translateBy(x: frame.minX, y: frame.minY)
            if layer.isGeometryFlipped == false && button.isFlipped {
                cg.translateBy(x: 0, y: frame.height)
                cg.scaleBy(x: 1, y: -1)
            }
            layer.render(in: cg)
            cg.restoreGState()
        }
    }
}

/// `ContentView` over a private in-memory History, with every service injected.
@MainActor
private final class CatalogWindow {
    let host: CatalogHost
    let model: ContentViewModel
    let store: RecordingStore
    let database: DatabaseQueue
    let service: TranscriptionService
    var backgroundTask: Task<Void, Never>?

    private init(host: CatalogHost, model: ContentViewModel, store: RecordingStore, database: DatabaseQueue, service: TranscriptionService) {
        self.host = host
        self.model = model
        self.store = store
        self.database = database
        self.service = service
    }

    static func makeStore() throws -> (DatabaseQueue, RecordingStore) {
        let database = try DatabaseQueue()
        let store = try RecordingStore(
            database: database, recordingsDirectory: Recording.recordingsDirectory,
            cancelQueuedRecording: { _ in }, stopPlayback: { _ in }
        )
        return (database, store)
    }

    static func make(database: DatabaseQueue, store: RecordingStore, rowCount: Int, size: CGSize, scheme: ColorScheme,
                     suite: UserDefaults, permissions: PermissionsManager?, engine: CatalogEngine, scripted: Bool,
                     waitForHistory: Bool, regeneratingID: UUID?) -> CatalogWindow {
        let service = TranscriptionService(engine: engine)
        let queue = TranscriptionQueue(
            transcriptionService: service,
            recordingStore: store,
            cleanupPipeline: TranscriptCleanupPipeline(
                isEnabled: { false },
                providerResolver: { throw CleanupProviderError.missingCredential("none") },
                vocabularyProvider: { [] },
                appRuleProvider: { _ in nil },
                bedrockBudgetProvider: { nil },
                filterProvider: { .builtIn(.everyday) },
                failureRecorder: { _ in }
            )
        )
        let model: ContentViewModel = scripted
            ? CatalogRecordingViewModel(transcriptionService: service, transcriptionQueue: queue, recordingStore: store)
            : ContentViewModel(transcriptionService: service, transcriptionQueue: queue, recordingStore: store)
        let content = ContentView(
            viewModel: model,
            permissionsManager: permissions ?? PermissionsManager(microphone: true, accessibility: true, inputMonitoring: true)
        )
        .tint(ThemePalette.controlTint)
        .environment(\.colorScheme, scheme)
        .environment(\.appearsActive, true)
        .environment(\.transcriptPasteboard, Catalog.pasteboard)
        .defaultAppStorage(suite)
        let host = CatalogHost(content, size: size, scheme: scheme, titled: true)
        let window = CatalogWindow(host: host, model: model, store: store, database: database, service: service)
        if waitForHistory {
            host.settle(0.3, timeout: 6) { model.recordings.count == rowCount && !model.isLoadingMore }
        } else {
            host.settle(0.3)
        }
        if let regeneratingID {
            NotificationCenter.default.post(name: RecordingStore.recordingProgressDidUpdateNotification, object: nil, userInfo: [
                "id": regeneratingID, "progress": Float(0.4), "status": RecordingStatus.transcribing, "isRegeneration": true,
            ])
            host.settle(0.2)
        }
        return window
    }

    func close() {
        backgroundTask?.cancel()
        host.close()
    }

    /// Types into the toolbar's search field the way AppKit reports typing,
    /// then waits out the search debounce, the store query, and highlighting.
    func search(_ query: String) {
        guard let field = host.allViews.compactMap({ $0 as? NSSearchField }).first else { return }
        let previous = model.recordings.map(\.id)
        field.stringValue = query
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        host.settle(0.2, timeout: 3) { self.model.recordings.map(\.id) != previous && !self.model.isLoadingMore }
        host.settle(0.6)
    }

    var historyScrollView: NSScrollView? {
        host.allViews.compactMap { $0 as? NSScrollView }
            .first { !($0.documentView is NSTextView) && host.frameInHost($0).height > 60 }
    }

    /// Show full text on the long transcript at the top of History.
    func expandLongTranscript() -> Bool {
        guard let list = historyScrollView,
              let toggle = host.buttons.first(where: { $0.isDescendant(of: list) && $0.frame.width > 40 }) else { return false }
        toggle.performClick(nil)
        host.settle(0.6)
        return true
    }
}

/// Stands in for a live microphone session, which only the recorder can own.
private final class CatalogRecordingViewModel: ContentViewModel {
    var scriptedRecording = false
    override var isRecording: Bool { scriptedRecording }
}

// MARK: - Scripted services

/// Lets an async caller wait until the test opens it.
private final class CatalogGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

/// A loaded speech engine that returns fixed words, optionally held by a gate.
private final class CatalogEngine: TranscriptionEngine, @unchecked Sendable {
    let isModelLoaded = true
    let engineName = "Catalog fixture"
    private let text: String
    private let gate: CatalogGate?

    init(text: String = "Catalog fixture words", gate: CatalogGate? = nil) {
        self.text = text
        self.gate = gate
    }

    func initialize() async throws {}
    func getSupportedLanguages() -> [String] { ["en"] }
    func cancelTranscription() {}

    func transcribeAudio(url: URL, settings: OpenSuperWhisper.Settings) async throws -> String {
        if let gate { await gate.wait() }
        return text
    }
}

/// A cleanup provider that holds every request until the gate opens.
private final class CatalogGatedCleanup: TranscriptCleanupProviding, @unchecked Sendable {
    let providerID: CleanupProviderID = .ollama
    private let gate: CatalogGate

    init(gate: CatalogGate) { self.gate = gate }

    func clean(transcript: String, systemPrompt: String, filter: CleanupFilterSnapshot) async throws -> CleanupProviderResult {
        await gate.wait()
        return CleanupProviderResult(text: transcript, inputTokens: 40, outputTokens: 12, modelID: "catalog-local")
    }
}

/// A chat provider with a scripted reply or failure, optionally held by a gate.
private final class CatalogChat: CleanupChatCompleting, @unchecked Sendable {
    let providerID: CleanupProviderID
    private let gate: CatalogGate?
    private let failure: Error?
    private let respond: (ProviderChatRequest) -> String

    init(providerID: CleanupProviderID = .ollama, gate: CatalogGate? = nil, failure: Error? = nil,
         respond: @escaping (ProviderChatRequest) -> String = { _ in Catalog.assistantReply }) {
        self.providerID = providerID
        self.gate = gate
        self.failure = failure
        self.respond = respond
    }

    func complete(_ request: ProviderChatRequest) async throws -> CleanupProviderResult {
        if let gate { await gate.wait() }
        if let failure { throw failure }
        return CleanupProviderResult(text: respond(request), inputTokens: 640, outputTokens: 180, modelID: "llama3.2:3b")
    }
}

/// Holds the History database in a write until released, so the first page stays loading.
private final class CatalogDatabaseLock: @unchecked Sendable {
    private let held = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private var isHolding = false

    func hold(_ database: DatabaseQueue) {
        isHolding = true
        let held = held
        let released = released
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? database.write { _ in
                held.signal()
                released.wait()
            }
        }
        held.wait()
    }

    func release() {
        guard isHolding else { return }
        isHolding = false
        released.signal()
    }
}

private struct CatalogError: LocalizedError {
    var message = "History could not be read."
    var errorDescription: String? { message }
}

private final class CatalogResultBox<T> {
    var result: Result<T, Error>?
}

// MARK: - Cases

private struct CatalogRowCase {
    let state: String
    let recording: Recording
    var widths: [CGFloat]
    var query: String
    var playing: Bool
    var audio: Bool
    var expand: Bool
    var note: String

    init(_ state: String, _ recording: Recording, widths: [CGFloat] = [560], query: String = "", playing: Bool = false,
         audio: Bool = true, expand: Bool = false, note: String = "") {
        self.state = state
        self.recording = recording
        self.widths = widths
        self.query = query
        self.playing = playing
        self.audio = audio
        self.expand = expand
        self.note = note
    }
}

private struct CatalogDockCase {
    let state: String
    let status: DictationDockStatus
    var widths: [CGFloat]
    var shortcut: String
    var filters: [CustomCleanupFilter]
    var auto: Bool?
    var selection: CleanupFilterSelection
    var microphones: [MicrophoneService.AudioDevice]
    var learn: Bool
    var microphoneMenu: Bool
    var live: Bool
    var note: String

    init(_ state: String, _ status: DictationDockStatus, widths: [CGFloat] = [560], shortcut: String = "⌃ / fn",
         filters: [CustomCleanupFilter] = [], auto: Bool? = nil, selection: CleanupFilterSelection = .builtIn(.everyday),
         microphones: [MicrophoneService.AudioDevice] = [Catalog.microphone, Catalog.headset],
         learn: Bool = true, microphoneMenu: Bool = true, live: Bool = false, note: String = "") {
        self.state = state
        self.status = status
        self.widths = widths
        self.shortcut = shortcut
        self.filters = filters
        self.auto = auto
        self.selection = selection
        self.microphones = microphones
        self.learn = learn
        self.microphoneMenu = microphoneMenu
        self.live = live
        self.note = note
    }
}

private struct CatalogIndicatorCase {
    let name: String
    let state: RecordingState
    var levels: [CGFloat]?
    var elapsed: TimeInterval?
    var confirmCancel: Bool
    var finalizing: Bool
    var note: String

    init(_ name: String, _ state: RecordingState, levels: [CGFloat]? = nil, elapsed: TimeInterval? = nil,
         confirmCancel: Bool = false, finalizing: Bool = false, note: String = "") {
        self.name = name
        self.state = state
        self.levels = levels
        self.elapsed = elapsed
        self.confirmCancel = confirmCancel
        self.finalizing = finalizing
        self.note = note
    }
}

private struct CatalogCardCase {
    let state: String
    var widths: [CGFloat]
    var filters: [CustomCleanupFilter]
    var selection: CleanupFilterSelection?
    var auto: Bool
    var draft: CustomCleanupFilter?
    var search: String?
    var note: String

    init(_ state: String, widths: [CGFloat] = [620], filters: [CustomCleanupFilter] = [],
         selection: CleanupFilterSelection? = nil, auto: Bool = false, draft: CustomCleanupFilter? = nil,
         search: String? = nil, note: String = "") {
        self.state = state
        self.widths = widths
        self.filters = filters
        self.selection = selection
        self.auto = auto
        self.draft = draft
        self.search = search
        self.note = note
    }
}

private struct CatalogSettingsVariant {
    let pane: SettingsPane
    let state: String
    var defaults: [String: Any?]
    var credentials: StoredCredentialStatus
    var suite: ((UserDefaults) -> Void)?
    var standard: (() -> Void)?
    var note: String

    init(_ pane: SettingsPane, _ state: String, defaults: [String: Any?] = [:],
         credentials: StoredCredentialStatus = Catalog.credentials(),
         suite: ((UserDefaults) -> Void)? = nil, standard: (() -> Void)? = nil, note: String = "") {
        self.pane = pane
        self.state = state
        self.defaults = defaults
        self.credentials = credentials
        self.suite = suite
        self.standard = standard
        self.note = note
    }
}

// MARK: - Index records

private enum CatalogFamily {
    static let main = "main-window"
    static let rows = "history-rows"
    static let dock = "dock-and-button"
    static let indicator = "indicator"
    static let settings = "settings"
    static let other = "other"
    static let order = [main, rows, dock, indicator, settings, other]
}

private struct CatalogRow: Codable {
    var file: String
    var family: String
    var screen: String
    var state: String
    var scheme: String
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var viewType: String
    var source: String
    var method: String
    var note: String
    var backingScale: Double
    var animated: Bool

    init(file: String, family: String, screen: String, state: String, scheme: String, width: Int, height: Int,
         pixelWidth: Int, pixelHeight: Int, viewType: String, source: String, method: String, note: String,
         backingScale: Double, animated: Bool) {
        self.file = file
        self.family = family
        self.screen = screen
        self.state = state
        self.scheme = scheme
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.viewType = viewType
        self.source = source
        self.method = method
        self.note = note
        self.backingScale = backingScale
        self.animated = animated
    }

    /// Rows written before the flag existed read as not animated.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(String.self, forKey: .file)
        family = try container.decode(String.self, forKey: .family)
        screen = try container.decode(String.self, forKey: .screen)
        state = try container.decode(String.self, forKey: .state)
        scheme = try container.decode(String.self, forKey: .scheme)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        viewType = try container.decode(String.self, forKey: .viewType)
        source = try container.decode(String.self, forKey: .source)
        method = try container.decode(String.self, forKey: .method)
        note = try container.decode(String.self, forKey: .note)
        backingScale = try container.decode(Double.self, forKey: .backingScale)
        animated = try container.decodeIfPresent(Bool.self, forKey: .animated) ?? false
    }
}

private struct CatalogUnreached {
    let state: String
    let view: String
    let why: String
}

/// Where views and the state they hold are declared, read from the sources
/// at run time so line numbers follow edits.
@MainActor
private enum CatalogSource {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let viewFiles = [
        "OpenSuperWhisper/ContentView.swift",
        "OpenSuperWhisper/Indicator/IndicatorWindow.swift",
        "OpenSuperWhisper/Design/RecordButton.swift",
        "OpenSuperWhisper/Design/WorkFlowDesign.swift",
        "OpenSuperWhisper/Design/SettingsLayout.swift",
        "OpenSuperWhisper/SettingsView.swift",
        "OpenSuperWhisper/DictationSettingsView.swift",
        "OpenSuperWhisper/CleanupSettingsView.swift",
        "OpenSuperWhisper/CustomCleanupFilterViews.swift",
        "OpenSuperWhisper/FilterAssistantView.swift",
        "OpenSuperWhisper/CorrectionLearningView.swift",
        "OpenSuperWhisper/SpeakingEfficiencyViews.swift",
        "OpenSuperWhisper/Onboarding/OnboardingView.swift",
        "OpenSuperWhisper/FileDropHandler.swift",
    ]
    private static var cache: [String: [String]] = [:]

    static func lines(of file: String) -> [String] {
        if let cached = cache[file] { return cached }
        let text = (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) ?? ""
        let lines = text.components(separatedBy: "\n")
        cache[file] = lines
        return lines
    }

    /// `file:line` of the first line containing `needle`.
    static func line(_ file: String, _ needle: String) -> String {
        guard let index = lines(of: file).firstIndex(where: { $0.contains(needle) }) else { return "\(file):?" }
        return "\(file):\(index + 1)"
    }

    /// Where a view type is declared.
    static func declaration(of type: String) -> String {
        let patterns = ["struct \(type): ", "struct \(type)<", "class \(type): "]
        for file in viewFiles {
            if let index = lines(of: file).firstIndex(where: { line in patterns.contains { line.contains($0) } }) {
                return "\(file):\(index + 1)"
            }
        }
        return "?"
    }
}

private struct CatalogNotCapturable {
    let state: String
    let view: String
    let file: String
    let needle: String
    let why: String

    static let all: [CatalogNotCapturable] = [
        CatalogNotCapturable(
            state: "Whole window while a meeting records or saves", view: "ContentView / DictationControls",
            file: "OpenSuperWhisper/MeetingSessionController.swift", needle: "@Published private(set) var state",
            why: "MeetingSessionController.shared.state is private(set), and only a real microphone session moves it. MainToolbar and DictationDock are rendered standalone in the meeting and saving states instead."
        ),
        CatalogNotCapturable(
            state: "Whole window listening with a running clock (0:07, 12:34)", view: "DictationControls",
            file: "OpenSuperWhisper/ContentView.swift", needle: "@Published private(set) var recordingStartedAt",
            why: "Set to the current time when recording starts, so the window shows 0:00. The dock family renders DictationDockStatus.recording(7) and .recording(754)."
        ),
        CatalogNotCapturable(
            state: "Whole window while the speech model loads", view: "DictationControls",
            file: "OpenSuperWhisper/TranscriptionService.swift", needle: "@Published private(set) var isLoading",
            why: "Set only while a real speech engine loads. The dock family renders .loadingModel."
        ),
        CatalogNotCapturable(
            state: "A row playing inside the window", view: "RecordingRow",
            file: "OpenSuperWhisper/ContentView.swift", needle: "@State private var isPlaying = false",
            why: "Private @State that follows AudioRecorder.shared playback, which needs real audio output. HistoryRow is rendered with isPlaying: true instead."
        ),
        CatalogNotCapturable(
            state: "Hover plate on toolbar and row glyphs", view: "ToolbarGlyph",
            file: "OpenSuperWhisper/Design/WorkFlowDesign.swift", needle: "@State private var isHovered = false",
            why: "Private @State set only by onHover, which needs a real pointer."
        ),
        CatalogNotCapturable(
            state: "Record button hover lift", view: "RecordButtonFace",
            file: "OpenSuperWhisper/Design/RecordButton.swift", needle: "@State private var isHovered = false",
            why: "Private @State set only by onHover, which needs a real pointer. Disabled is drawn by phase (working, unavailable) and is captured."
        ),
        CatalogNotCapturable(
            state: "History row hover", view: "HistoryRow",
            file: "OpenSuperWhisper/ContentView.swift", needle: "private var rowActions: some View",
            why: "Not a state: the row's actions are always visible, so there is no hovered variant beyond ToolbarGlyph's plate above."
        ),
        CatalogNotCapturable(
            state: "Pressed state of any button", view: "Button with system styles",
            file: "OpenSuperWhisper/ContentView.swift", needle: "Button(action: onRecord)",
            why: "AppKit draws the pressed look only while a real mouse button is held down."
        ),
        CatalogNotCapturable(
            state: "Keyboard focus ring", view: "SearchField and every focusable control",
            file: "OpenSuperWhisper/Design/WorkFlowDesign.swift", needle: "struct SearchField: NSViewRepresentable",
            why: "Focus rings draw only in the key window, and an offscreen window that is never ordered in cannot become key."
        ),
        CatalogNotCapturable(
            state: "Open menus and pickers", view: "MainToolbar More menu, HistoryRow actions and context menu, MicrophoneMenu, WritingFilterPicker, every Picker",
            file: "OpenSuperWhisper/ContentView.swift", needle: "Menu {",
            why: "A menu opens in its own window, which would appear on screen."
        ),
        CatalogNotCapturable(
            state: "Alerts and confirmation dialogs", view: "ContentView, ProviderCostSettingsView, CustomCleanupFiltersCard, CorrectionLearningCard, RecordingStorageSettingsView",
            file: "OpenSuperWhisper/ContentView.swift", needle: ".confirmationDialog(",
            why: "Delete All, the meeting name prompt, recording and deletion failures, Remove Key, Delete Filter, Reset learned preferences, and Delete Old Recordings each present a visible window or sheet."
        ),
        CatalogNotCapturable(
            state: "Settings presented as a sheet on the main window", view: "ContentView",
            file: "OpenSuperWhisper/ContentView.swift", needle: ".sheet(isPresented: $isSettingsPresented)",
            why: "A sheet attaches a visible window. SettingsView is rendered standalone at the sizes the sheet uses."
        ),
        CatalogNotCapturable(
            state: "Filter assistant presented as a sheet", view: "CustomCleanupFiltersCard",
            file: "OpenSuperWhisper/CustomCleanupFilterViews.swift", needle: ".sheet(item: $assistant)",
            why: "A sheet attaches a visible window. FilterAssistantSheet is rendered standalone with injected sessions."
        ),
        CatalogNotCapturable(
            state: "Provider connection test in progress (Testing…)", view: "ProviderCostSettingsView",
            file: "OpenSuperWhisper/CleanupSettingsView.swift", needle: "@State private var isTesting = false",
            why: "Private @State (and SettingsViewModel.isTestingBedrock is private(set)). Only a real connection test sets it, and that reads Keychain and sends a network request."
        ),
        CatalogNotCapturable(
            state: "Status after a connection test (Connected, Connection failed, key removed) for direct providers", view: "ProviderCostSettingsView",
            file: "OpenSuperWhisper/CleanupSettingsView.swift", needle: "@State private var providerStatus = \"\"",
            why: "Private @State set only by a real test or key removal. The Bedrock status line is captured through the credential stub's error."
        ),
        CatalogNotCapturable(
            state: "Download models expanded", view: "DictationSettingsView",
            file: "OpenSuperWhisper/DictationSettingsView.swift", needle: "@State private var showsModels = false",
            why: "Private @State toggled only by SettingsDisclosureRow, a plain SwiftUI button: SwiftUI draws it itself (no NSButton) and exposes no accessibility element offscreen, so only a real click opens it."
        ),
        CatalogNotCapturable(
            state: "More options expanded (sounds, Escape, startup, meetings, History storage, Whisper decoding)", view: "DictationSettingsView",
            file: "OpenSuperWhisper/DictationSettingsView.swift", needle: "@State private var showsMoreOptions = false",
            why: "Private @State toggled only by a plain SwiftUI button, as above."
        ),
        CatalogNotCapturable(
            state: "Usage this month expanded", view: "ProviderCostSettingsView",
            file: "OpenSuperWhisper/CleanupSettingsView.swift", needle: "@State private var showsUsage = false",
            why: "Private @State toggled only by a plain SwiftUI button, as above."
        ),
        CatalogNotCapturable(
            state: "How it’s calculated expanded", view: "SpeakingSettingsGroup",
            file: "OpenSuperWhisper/SpeakingEfficiencyViews.swift", needle: "@State private var showsMethod = false",
            why: "Private @State toggled only by a plain SwiftUI button, as above."
        ),
        CatalogNotCapturable(
            state: "Collapsed filter groups opened by hand in a large collection", view: "CustomCleanupFiltersCard",
            file: "OpenSuperWhisper/CustomCleanupFilterViews.swift", needle: "@State private var expandedGroups: Set<CleanupMode>?",
            why: "Private @State toggled only by the plain group-header buttons. The search shots show every matching group open instead."
        ),
        CatalogNotCapturable(
            state: "Editing a saved filter, and the editor's validation error", view: "CustomCleanupFiltersCard",
            file: "OpenSuperWhisper/CustomCleanupFilterViews.swift", needle: "@State private var draft: CustomCleanupFilter?",
            why: "draft and errorMessage are private @State set only by the pencil and Save buttons, which SwiftUI draws itself. The editor is captured for new drafts through init(writingFilter:newDraft:)."
        ),
        CatalogNotCapturable(
            state: "Learn details expanded", view: "CorrectionLearningCard",
            file: "OpenSuperWhisper/CorrectionLearningView.swift", needle: "@State private var showsDetails = false",
            why: "Private @State bound to a DisclosureGroup that SwiftUI draws itself, so only a real click opens it."
        ),
        CatalogNotCapturable(
            state: "Tooltips", view: ".help(_:) on every control",
            file: "OpenSuperWhisper/ContentView.swift", needle: ".help(",
            why: "AppKit shows them in a separate window after a real pointer rests on a control."
        ),
        CatalogNotCapturable(
            state: "Drop target highlight on the learning document", view: "CorrectionLearningCard",
            file: "OpenSuperWhisper/CorrectionLearningView.swift", needle: "@State private var isDropTargeted = false",
            why: "Private @State set only by a real drag session."
        ),
        CatalogNotCapturable(
            state: "File chooser for Add File…", view: "CorrectionLearningCard",
            file: "OpenSuperWhisper/CorrectionLearningView.swift", needle: "@State private var isChoosingFile = false",
            why: "Opens a visible open panel. The loaded-file result is captured through load(_:) with a synthetic file."
        ),
        CatalogNotCapturable(
            state: "Model download in progress", view: "DictationSettingsView, OnboardingUnifiedModelItemView",
            file: "OpenSuperWhisper/Settings.swift", needle: "@Published var isDownloading: Bool = false",
            why: "Reached only by a real download over the network; the onboarding view model is a private @StateObject."
        ),
        CatalogNotCapturable(
            state: "Onboarding shortcut card chosen by click, Asian autocorrect toggle", view: "OnboardingView",
            file: "OpenSuperWhisper/Onboarding/OnboardingView.swift", needle: "@StateObject private var viewModel = OnboardingViewModel()",
            why: "The view model is a private @StateObject. Each shortcut is seeded through preferences instead; the Asian toggle follows the system language. Onboarding has one screen, so there are no further steps."
        ),
        CatalogNotCapturable(
            state: "Background audio reduction notice", view: "BackgroundAudioReductionNotice",
            file: "OpenSuperWhisper/DictationSettingsView.swift", needle: "@ObservedObject private var monitor = BackgroundAudioReductionMonitor.shared",
            why: "Its status comes from a real voice-processed recording."
        ),
        CatalogNotCapturable(
            state: "Shortcut recorder while recording a key combination", view: "KeyboardShortcuts.Recorder",
            file: "OpenSuperWhisper/DictationSettingsView.swift", needle: "KeyboardShortcuts.Recorder(",
            why: "Needs keyboard focus and real key presses."
        ),
        CatalogNotCapturable(
            state: "Floating indicator appear and hide animation, and a dragged position", view: "IndicatorWindowManager",
            file: "OpenSuperWhisper/Indicator/IndicatorWindowManager.swift", needle: "CASpringAnimation",
            why: "Runs on the real panel's layer on screen. The capsule itself is rendered in every state."
        ),
        CatalogNotCapturable(
            state: "Personalization export and import status", view: "PersonalizationSettingsView",
            file: "OpenSuperWhisper/CleanupSettingsView.swift", needle: "@State private var archiveStatus = \"\"",
            why: "Set only after a visible save or open panel."
        ),
        CatalogNotCapturable(
            state: "Speaking strip with no data", view: "SpeakingSummaryStrip",
            file: "OpenSuperWhisper/SpeakingEfficiencyViews.swift", needle: "if let text = presentation.stripText",
            why: "Renders nothing, by design. The main window shots without speaking data show its absence."
        ),
        CatalogNotCapturable(
            state: "Search field with focus and a caret", view: "SearchField",
            file: "OpenSuperWhisper/Design/WorkFlowDesign.swift", needle: "func makeNSView(context: Context) -> NSSearchField",
            why: "Needs the key window. Search results are captured by setting the field's text through its delegate."
        ),
    ]
}

// MARK: - Run loop helper

@MainActor
private func spin(timeout: TimeInterval, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
}

// MARK: - Synthetic fixtures

/// Invented data only: no row, name, or value comes from a real History.
private enum Catalog {
    static let microphone = MicrophoneService.AudioDevice(id: "catalog-built-in", name: "MacBook Pro Microphone", manufacturer: nil, isBuiltIn: true)
    static let headset = MicrophoneService.AudioDevice(id: "catalog-usb", name: "USB Headset", manufacturer: "Fixture Audio", isBuiltIn: false)
    static let pasteboard = NSPasteboard.Name("UIScreenshotCatalogTests-private")
    static let longShortcut = "⌃⌥⇧⌘ Space / Middle mouse button"
    static let loudLevels: [CGFloat] = [0.18, 0.42, 0.66, 0.51, 0.83, 0.62, 0.74, 0.47, 0.58]
    static let syntheticAudioURL = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-synthetic.wav")
    static let mainSizes = [CGSize(width: 440, height: 460), CGSize(width: 560, height: 720), CGSize(width: 900, height: 800)]
    static let onboardingSizes: [(size: CGSize, label: String)] = [
        (CGSize(width: 560, height: 720), "the window's default size"),
        (CGSize(width: 440, height: 460), "the window's minimum size"),
        (CGSize(width: 440, height: 720), "the narrowest width, tall enough to show the shortcut cards"),
        (CGSize(width: 720, height: 720), "a wide window"),
    ]

    static let longText = """
    The community garden on Elm Street opened its second season with forty raised beds, a shared tool shed, and a rain barrel system the volunteers built over the winter. Each bed is assigned for the full season, and the waiting list already has twelve names on it.

    The planning group agreed on three changes for this year. Watering shifts will rotate weekly instead of monthly, the compost bins will move closer to the gate, and every Saturday morning will start with a short walk-through so new members can ask questions.

    The next open meeting is on the first Tuesday of the month at the library annex. Bring seeds to swap, ideas for the fall harvest table, and any notes about what grew well last year.
    """

    static let threeFilters: [CustomCleanupFilter] = [
        CustomCleanupFilter(name: "Calculus", baseMode: .homework, instructions: "Write math notation compactly, with exponents as superscripts.",
                            writesDigits: true, triggers: ["derivative", "integral", "limit"]),
        CustomCleanupFilter(name: "Standup notes", baseMode: .writing, instructions: "Write short standup sentences that start with the verb."),
        CustomCleanupFilter(name: "Release notes", baseMode: .technical, instructions: "Use present tense and name each changed setting exactly.",
                            triggers: ["changelog", "release"]),
    ]

    static let largeCollection: [CustomCleanupFilter] = threeFilters + [
        CustomCleanupFilter(name: "Biology lab", baseMode: .homework, instructions: "Name each sample with its label and write measurements as digits.",
                            writesDigits: true, triggers: ["specimen", "microscope"]),
        CustomCleanupFilter(name: "Chemistry notes", baseMode: .homework, instructions: "Write chemical formulas with subscripts and keep units.",
                            triggers: ["molar", "titration"]),
        CustomCleanupFilter(name: "History essay", baseMode: .writing, instructions: "Keep full sentences and spell out centuries."),
        CustomCleanupFilter(name: "Product spec", baseMode: .technical, instructions: "Use numbered requirements and exact field names.",
                            triggers: ["requirement", "acceptance"]),
        CustomCleanupFilter(name: "Bug report", baseMode: .technical, instructions: "Start with the observed behavior, then the expected behavior."),
        CustomCleanupFilter(name: "Email reply", baseMode: .everyday, instructions: "Keep a warm opening and a one-line sign-off."),
        CustomCleanupFilter(name: "Team chat", baseMode: .everyday, instructions: "Short sentences, no greeting."),
        CustomCleanupFilter(name: "Poetry draft", baseMode: .writing, instructions: "Keep line breaks exactly where I pause."),
        CustomCleanupFilter(name: "Recipe card", baseMode: .everyday, instructions: "List ingredients first, then numbered steps.", writesDigits: true),
    ]

    static let fiftyFilters: [CustomCleanupFilter] = (1...50).map { index in
        CustomCleanupFilter(
            name: String(format: "Course %02d notes", index),
            baseMode: CleanupMode.allCases[index % CleanupMode.allCases.count],
            instructions: "Keep the vocabulary for course \(index) exactly as written."
        )
    }

    static let vocabulary = [
        VocabularyEntry(spoken: "work flow", replacement: "WorkFlow"),
        VocabularyEntry(spoken: "elm street garden", replacement: "Elm Street Garden"),
        VocabularyEntry(spoken: "jason file", replacement: "JSON file", isEnabled: false),
    ]

    static let appRules = [
        TargetAppRule(bundleID: "com.example.notes", appName: "Notes Fixture", cleanupBehavior: .enabled,
                      pasteBehavior: .appDefault, cleanupInstruction: "Keep bullet points short."),
        TargetAppRule(bundleID: "com.example.chat", appName: "Chat Fixture", cleanupBehavior: .inherit, pasteBehavior: .copyOnly),
    ]

    static func learnedPreferences(_ mode: CleanupMode) -> [LearnedPreference] {
        [
            LearnedPreference(mode: mode, kind: .semicolonJoin, from: nil, to: nil, origin: .cleanup, evidence: ["a", "b"],
                              fromLegacyOnly: false, learnedAt: Date(), updatedAt: Date()),
            LearnedPreference(mode: mode, kind: .spelling, from: "note book", to: "notebook", origin: .recognition,
                              evidence: ["c"], fromLegacyOnly: false, learnedAt: Date(), updatedAt: Date()),
            LearnedPreference(mode: mode, kind: .removeFiller, from: "basically", to: nil, isEnabled: false, origin: .finalEdit,
                              evidence: ["d"], fromLegacyOnly: true, learnedAt: Date(), updatedAt: Date()),
        ]
    }

    static let assistantReply: String = {
        let object: [String: Any] = [
            "message": "Here is a filter for physics problem sets. It writes quantities as digits and uses × for multiplication.",
            "filter": [
                "name": "Physics sets",
                "base_mode": "homework",
                "instructions": "Write quantities as digits, use × for multiplication, and keep units after numbers.",
                "digits": true,
                "triggers": ["velocity", "acceleration"],
            ] as [String: Any],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }()

    static let learningSentences = [
        "The museum opened a new wing for modern sculpture last spring and the crowds have not slowed down since then.",
        "Our guide explained how each piece was cast in bronze and the method dates back several thousand years.",
    ]

    static let learningDocument = "Museum visit notes\n\n"
        + learningSentences[0].replacingOccurrences(of: "last spring and", with: "last spring; and")
        + "\n\n"
        + learningSentences[1].replacingOccurrences(of: "in bronze and", with: "in bronze; and")

    static func learningCandidates() -> [CorrectionCandidate] {
        learningSentences.enumerated().map { index, sentence in
            CorrectionCandidate(timestamp: Date().addingTimeInterval(-86_400 - Double(index) * 600), emitted: sentence,
                                cleanupInput: sentence, recognizer: sentence, provenance: .mode(.writing))
        }
    }

    /// A careful provider's answer: every numbered edit is a semicolon join.
    static func learningReply(_ request: ProviderChatRequest) -> String {
        let content = request.messages.last?.content ?? ""
        let pattern = try? NSRegularExpression(pattern: #"^(\d+) \["#, options: [.anchorsMatchLines])
        let numbers = (pattern?.matches(in: content, range: NSRange(content.startIndex..., in: content)) ?? []).compactMap { match in
            Range(match.range(at: 1), in: content).flatMap { Int(content[$0]) }
        }
        let edits = numbers.isEmpty ? "[1]" : "[\(numbers.map(String.init).joined(separator: ", "))]"
        return #"{"preferences": [{"kind": "semicolon_join", "edits": \#(edits)}]}"#
    }

    static func credentials(bedrock: Bool = true, cleanup: Set<CleanupCredentialAccount> = [], failing: Bool = false) -> StoredCredentialStatus {
        StoredCredentialStatus(
            bedrock: {
                if failing { throw BedrockCredentialStoreError.keychain(-25308) }
                return bedrock
            },
            cleanup: { cleanup.contains($0) }
        )
    }

    static func recordDraftUsage(input: Int, output: Int) {
        FilterAssistantUsageStore.record(providerID: .bedrock, modelID: BedrockCleanupConfiguration.defaultModelID,
                                         inputTokens: input, outputTokens: output)
    }

    static func paneView(_ pane: SettingsPane) -> String {
        switch pane {
        case .dictation: "DictationSettingsView"
        case .cleanup: "CleanupSettingsView"
        case .personalize: "PersonalizationSettingsView"
        case .providerCost: "ProviderCostSettingsView"
        }
    }

    static func fallbackSettingsHeight(_ pane: SettingsPane) -> CGFloat {
        switch pane {
        case .dictation: 1450
        case .cleanup: 1500
        case .personalize: 1250
        case .providerCost: 1350
        }
    }

    static func hideHistoryTable(_ database: DatabaseQueue) throws {
        try database.write { db in
            try db.execute(sql: "ALTER TABLE recordings RENAME TO catalog_hidden_recordings")
        }
    }

    static func recording(_ text: String, at date: Date, seconds: TimeInterval, status: RecordingStatus = .completed,
                          progress: Float = 1, source: TranscriptCleanupOutcome.Source? = .disabled, tokens: (Int, Int)? = nil,
                          model: String? = nil, mode: CleanupMode? = nil, meeting: String? = nil, file: String? = nil) -> Recording {
        let id = UUID()
        var row = Recording(id: id, timestamp: date, fileName: "catalog-\(id.uuidString).wav", transcription: text,
                            duration: seconds, status: status, progress: progress)
        row.sourceFileURL = file
        row.cleanupSource = status == .completed ? source : nil
        row.cleanupInputTokens = tokens?.0
        row.cleanupOutputTokens = tokens?.1
        row.cleanupModelID = model
        row.cleanupMode = mode
        row.cleanupRequested = source != nil && source != .disabled
        if let meeting {
            row.mode = .meeting
            row.title = meeting
        }
        return row
    }

    static func source(for row: Recording, measured: Bool) -> DictationSource {
        var source = DictationSource(
            recordingID: row.id, recordingStartedAt: row.timestamp.addingTimeInterval(-row.duration),
            recognizerText: row.transcription, emittedText: row.transcription, insertedText: row.transcription,
            disposition: .pasteSent, filter: .builtIn(row.cleanupMode ?? .everyday), cleanupSource: row.cleanupSource,
            captureOrigin: .live, processingSeconds: 0.9, speechActivity: measured ? .measured : nil
        )
        if measured { source.activeSpeechSeconds = row.duration * 0.72 }
        return source
    }

    struct History {
        let rows: [Recording]
        let measured: [DictationSource]
        let unmeasured: [DictationSource]
        let regeneratingID: UUID
        let audio: [URL]
    }

    /// Thirty synthetic dictations over three days, newest first.
    static func history(now: Date) throws -> History {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        // Fixed times of day, so two runs differ only in the date labels.
        let anchor = today.addingTimeInterval(10 * 3_600 + 30 * 60)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        let earlier = calendar.date(byAdding: .day, value: -2, to: today) ?? today.addingTimeInterval(-172_800)
        func todayAt(_ step: Int) -> Date { anchor.addingTimeInterval(-Double(step) * 360 - 30) }
        func yesterdayAt(_ step: Int) -> Date { yesterday.addingTimeInterval(18 * 3_600 - Double(step) * 1_200) }
        func earlierAt(_ step: Int) -> Date { earlier.addingTimeInterval(17 * 3_600 - Double(step) * 1_500) }
        let nova = BedrockCleanupConfiguration.defaultModelID

        let failed = recording("Failed to transcribe: The speech model could not process the audio.", at: todayAt(4), seconds: 12,
                               status: .failed, progress: 0, source: nil)
        let regenerating = recording("Send the revised budget to finance before Friday.", at: todayAt(5), seconds: 4,
                                     source: .openAI, tokens: (190, 28), mode: .everyday)
        var calculus = recording("The derivative of 3x² is 6x, and the integral brings it back.", at: todayAt(7), seconds: 6,
                                 source: .anthropic, tokens: (300, 40), mode: .homework)
        calculus.cleanupFilterName = "Calculus"
        calculus.cleanupFilterInstructions = threeFilters[0].instructions
        calculus.cleanupFilterWritesDigits = true
        calculus.cleanupFilterReason = .triggers(["derivative", "integral"])
        var fallback = recording("Ask the venue whether the projector supports HDMI.", at: yesterdayAt(5), seconds: 4,
                                 source: .ollama, tokens: (120, 20), mode: .everyday)
        fallback.cleanupFilterReason = .fallback

        let rows: [Recording] = [
            recording(longText, at: todayAt(0), seconds: 91, source: .bedrock, tokens: (980, 640), model: nova, mode: .writing),
            recording("Move the design review to Thursday afternoon.", at: todayAt(1), seconds: 3, source: .rawFallback, mode: .everyday),
            recording("", at: todayAt(2), seconds: 1_820, status: .transcribing, progress: 0.4, source: nil,
                      file: "/Users/Shared/Fixtures/Lecture 12.m4a"),
            recording("In queue...", at: todayAt(3), seconds: 1_340, status: .pending, progress: 0, source: nil,
                      file: "/Users/Shared/Fixtures/Weekly sync.m4a"),
            failed,
            regenerating,
            recording("We agreed to keep the current shortcuts, make failures easy to recover from, and review the first version on Friday.",
                      at: todayAt(6), seconds: 1_820, source: .disabled, meeting: "Planning sync"),
            calculus,
            recording("Add a retry with backoff to the upload client and cover it with a unit test.", at: todayAt(8), seconds: 5,
                      source: .bedrock, tokens: (198, 45), model: "us.fixture.unpriced-model-v1", mode: .technical),
            recording("Remind me to water the tomatoes after work.", at: todayAt(9), seconds: 3, source: .ollama, tokens: (90, 14), mode: .everyday),
            recording("Draft a short thank-you note to the team for staying late.", at: todayAt(10), seconds: 5, source: .budgetLimited, mode: .writing),
            recording("Pick up printer paper and two blue folders.", at: todayAt(11), seconds: 3, source: .disabled),

            recording("The draft is due Friday; I'll send the outline tonight so we can review it together.", at: yesterdayAt(0), seconds: 8,
                      source: .bedrock, tokens: (240, 38), model: nova, mode: .writing),
            recording("A small plan\nKeep the details\nMake it clear\nLeave room to think", at: yesterdayAt(1), seconds: 9, source: .disabled),
            recording("", at: yesterdayAt(2), seconds: 2, source: .disabled),
            recording("Book the meeting room for the quarterly review.", at: yesterdayAt(3), seconds: 3,
                      source: .azureOpenAI, tokens: (150, 24), mode: .everyday),
            recording("Rename the export button to Save a Copy.", at: yesterdayAt(4), seconds: 3,
                      source: .openAICompatible, tokens: (140, 22), mode: .technical),
            fallback,
            recording("Check whether the train leaves at eight or at nine.", at: yesterdayAt(6), seconds: 3, source: .rawFallback, mode: .everyday),
            recording("Order more coffee filters for the office kitchen.", at: yesterdayAt(7), seconds: 3, source: .anthropic, tokens: (110, 16), mode: .everyday),
            recording("Write the release notes after the last test passes.", at: yesterdayAt(8), seconds: 4,
                      source: .bedrock, tokens: (180, 30), model: nova, mode: .technical),
            recording("Reply to the landlord about the heating schedule.", at: yesterdayAt(9), seconds: 4, source: .openAI, tokens: (160, 26), mode: .everyday),

            recording("Summarize the survey results in three bullet points.", at: earlierAt(0), seconds: 4,
                      source: .bedrock, tokens: (170, 44), model: nova, mode: .everyday),
            recording("Call the dentist to move the cleaning to next week.", at: earlierAt(1), seconds: 3, source: .disabled),
            recording("Bring the extension cord to the workshop on Sunday.", at: earlierAt(2), seconds: 3, source: .ollama, tokens: (100, 15), mode: .everyday),
            recording("The photosynthesis lab needs two more beakers and a timer.", at: earlierAt(3), seconds: 4,
                      source: .bedrock, tokens: (160, 25), model: nova, mode: .homework),
            recording("Update the onboarding checklist with the new laptop steps.", at: earlierAt(4), seconds: 4,
                      source: .openAI, tokens: (150, 30), mode: .technical),
            recording("Thank the neighbors for watching the dog over the weekend.", at: earlierAt(5), seconds: 4,
                      source: .anthropic, tokens: (130, 22), mode: .writing),
            recording("Move the book club to the second floor reading room.", at: earlierAt(6), seconds: 3, source: .disabled),
            recording("Notes from the budget walkthrough: travel stays flat, training goes up slightly, and the equipment request moves to next quarter.",
                      at: earlierAt(7), seconds: 2_460, source: .disabled, meeting: "Budget walkthrough"),
        ]

        let comparable = rows.filter { $0.status == .completed && $0.mode == .dictation && !$0.transcription.isEmpty && $0.id != regenerating.id }
        let measuredRows = Array(comparable.prefix(14))
        try FileManager.default.createDirectory(at: Recording.recordingsDirectory, withIntermediateDirectories: true)
        try Data([0]).write(to: failed.url)
        return History(
            rows: rows,
            measured: measuredRows.map { source(for: $0, measured: true) },
            unmeasured: measuredRows.map { source(for: $0, measured: false) },
            regeneratingID: regenerating.id,
            audio: [failed.url]
        )
    }

    /// Rows for the speaking-versus-typing totals: measured live dictations,
    /// older ones without measured speech, meetings, and optionally dictations
    /// slower than typing.
    static func speakingRows(measured: Int, unmeasured: Int, meetings: Int, slow: Int = 0) -> [(Recording, DictationSource?)] {
        func words(_ count: Int) -> String {
            let pool = ["plan", "notes", "garden", "review", "draft", "budget", "outline", "schedule", "update", "summary"]
            return (0..<count).map { pool[$0 % pool.count] }.joined(separator: " ")
        }
        var result: [(Recording, DictationSource?)] = []
        func add(seconds: TimeInterval, active: TimeInterval?, spoken: Int, produced: Int) {
            let id = UUID()
            let row = Recording(id: id, timestamp: Date().addingTimeInterval(-Double(result.count + 1) * 600),
                                fileName: "catalog-speaking-\(id.uuidString).wav", transcription: words(produced),
                                duration: seconds, status: .completed, progress: 1)
            var source = DictationSource(
                recordingID: id, recognizerText: words(spoken), emittedText: words(produced),
                disposition: .pasteSent, filter: .builtIn(.everyday),
                captureOrigin: .live, processingSeconds: 1.2,
                speechActivity: active == nil ? nil : .measured
            )
            source.activeSpeechSeconds = active
            result.append((row, source))
        }
        for index in 0..<measured {
            add(seconds: 20 + Double(index), active: 14 + Double(index) / 2, spoken: 52 + index, produced: 48 + index)
        }
        for _ in 0..<unmeasured { add(seconds: 15, active: nil, spoken: 36, produced: 34) }
        for _ in 0..<slow { add(seconds: 50, active: 40, spoken: 10, produced: 10) }
        for _ in 0..<meetings {
            let id = UUID()
            var meeting = Recording(id: id, timestamp: Date().addingTimeInterval(-7_200), fileName: "catalog-meeting-\(id.uuidString).wav",
                                    transcription: words(400), duration: 600, status: .completed, progress: 1)
            meeting.mode = .meeting
            meeting.title = "Synthetic meeting"
            result.append((meeting, nil))
        }
        return result
    }
}
