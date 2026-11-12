import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// Hosts the whole `ContentView` in a titled window that is never shown, the
/// way the app's hidden-title-bar window holds it. History is a private
/// in-memory store with synthetic dictations, permissions are fixed answers,
/// the recognizer is a stub, Copy writes to a private pasteboard, and
/// preferences live in the test host's own domain and are restored
/// afterwards. Nothing reads Keychain, the general clipboard, the
/// microphone, or the user's History, and nothing presents a sheet or alert.
@MainActor
final class MainWindowLayoutTests: XCTestCase {
    /// The screenshot the captain reviewed, the window's minimum, and a wide window.
    static let sizes: [(name: String, size: CGSize)] = [
        ("screenshot", CGSize(width: 560, height: 720)),
        ("minimum", CGSize(width: 440, height: 460)),
        ("wide", CGSize(width: 900, height: 720)),
    ]
    nonisolated static let screenshot = CGSize(width: 560, height: 720)

    private static let savedKeys = [
        "modifierOnlyHotkey", "secondaryModifierOnlyHotkey", "mouseButtonHotkey",
        CustomCleanupFilterStore.modeKey, CustomCleanupFilterStore.selectedIDKey, CustomCleanupFilterStore.dataKey,
    ]
    private var originals: [String: Any?] = [:]
    private var appStorage: UserDefaults!
    private var appStorageSuite: String!
    private var savedMicrophones: [MicrophoneService.AudioDevice] = []
    private var savedCurrentMicrophone: MicrophoneService.AudioDevice?
    private var savedSelectedMicrophone: MicrophoneService.AudioDevice?
    private var pasteboard: NSPasteboard!
    private var fixtureAudio: [URL] = []

    override func setUp() {
        super.setUp()
        let standard = UserDefaults.standard
        for key in Self.savedKeys { originals[key] = standard.object(forKey: key) }
        // The screenshot's shortcut: Control, with Fn as the second key.
        standard.set(ModifierKey.leftControl.rawValue, forKey: "modifierOnlyHotkey")
        standard.set(ModifierKey.fn.rawValue, forKey: "secondaryModifierOnlyHotkey")
        standard.set(MouseButton.none.rawValue, forKey: "mouseButtonHotkey")
        CustomCleanupFilterStore.select(.builtIn(.homework))

        appStorageSuite = "MainWindowLayoutTests-\(UUID().uuidString)"
        appStorage = UserDefaults(suiteName: appStorageSuite)
        appStorage.set(ModifierKey.leftControl.rawValue, forKey: "modifierOnlyHotkey")
        CustomCleanupFilterStore.select(.builtIn(.homework), in: appStorage)

        let microphones = MicrophoneService.shared
        savedMicrophones = microphones.availableMicrophones
        savedCurrentMicrophone = microphones.currentMicrophone
        savedSelectedMicrophone = microphones.selectedMicrophone
        microphones.availableMicrophones = [MainWindowFixtures.microphone]
        microphones.currentMicrophone = MainWindowFixtures.microphone

        pasteboard = NSPasteboard(name: NSPasteboard.Name("MainWindowLayoutTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        let standard = UserDefaults.standard
        for (key, value) in originals {
            if let value { standard.set(value, forKey: key) } else { standard.removeObject(forKey: key) }
        }
        appStorage.removePersistentDomain(forName: appStorageSuite)
        let microphones = MicrophoneService.shared
        microphones.availableMicrophones = savedMicrophones
        microphones.currentMicrophone = savedCurrentMicrophone
        microphones.selectedMicrophone = savedSelectedMicrophone
        pasteboard.releaseGlobally()
        for url in fixtureAudio { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func host(
        _ recordings: [Recording] = MainWindowFixtures.history(),
        size: CGSize = MainWindowLayoutTests.screenshot,
        scheme: ColorScheme = .light,
        appStorage: UserDefaults? = nil,
        permissions: PermissionsManager? = nil,
        viewModel: ((TranscriptionService, TranscriptionQueue, RecordingStore) -> ContentViewModel)? = nil
    ) throws -> MainWindowHost {
        try MainWindowHost(recordings: recordings, size: size, scheme: scheme, appStorage: appStorage ?? self.appStorage,
                           pasteboard: pasteboard.name, permissions: permissions, viewModel: viewModel)
    }

    // MARK: - Renders

    func testWholeWindowAtScreenshotMinimumAndWideSizes() throws {
        for (name, size) in Self.sizes {
            for scheme in [ColorScheme.light, .dark] {
                let window = try host(size: size, scheme: scheme)
                save(try window.render(), name: "main-\(name)-\(scheme.label)")
                window.assertHistoryStaysBelowTheToolbar()
                window.assertControlsFitWithoutOverlapping()
                XCTAssertFalse(window.window.isVisible, "Visual verification must stay offscreen")
                window.close()
            }
        }
    }

    func testDictationStatesKeepHistoryInPlace() throws {
        var historyHeights: [String: CGFloat] = [:]
        for scheme in [ColorScheme.light, .dark] {
            for state in ["ready", "recording", "transcribing", "no-microphone"] {
                if state == "no-microphone" {
                    MicrophoneService.shared.availableMicrophones = []
                    MicrophoneService.shared.currentMicrophone = nil
                }
                defer {
                    MicrophoneService.shared.availableMicrophones = [MainWindowFixtures.microphone]
                    MicrophoneService.shared.currentMicrophone = MainWindowFixtures.microphone
                }
                let window = try host(scheme: scheme) {
                    ScriptedRecordingViewModel(transcriptionService: $0, transcriptionQueue: $1, recordingStore: $2)
                }
                let model = try XCTUnwrap(window.viewModel as? ScriptedRecordingViewModel)
                switch state {
                case "recording":
                    model.scriptedRecording = true
                    model.updateRecorderState(isRecording: true, isConnecting: false)
                case "transcribing":
                    model.state = .decoding
                default:
                    break
                }
                window.settle()
                save(try window.render(), name: "state-\(state)-\(scheme.label)")
                historyHeights[state] = try XCTUnwrap(window.historyScrollView).frame.height
                window.assertControlsFitWithoutOverlapping()

                let record = try XCTUnwrap(window.recordButton)
                XCTAssertNil(window.meetingStopButton, "Meeting recording lives in More until a meeting runs")
                XCTAssertEqual(window.popUps.filter { window.frameInHost($0).maxY <= WFChrome.titleBarHeight }.count, 1, "More")
                let canStartMeeting = MainToolbar.meetingAvailable(isMeetingRecording: false, isMeetingBusy: false, dictationState: model.state)
                switch state {
                case "ready":
                    XCTAssertTrue(record.isEnabled, "Start recording is available when ready")
                    XCTAssertTrue(canStartMeeting, "A meeting can start when ready")
                case "recording":
                    XCTAssertTrue(record.isEnabled, "Stop stays available while recording")
                    XCTAssertFalse(canStartMeeting, "No meeting over a dictation")
                case "transcribing":
                    XCTAssertFalse(record.isEnabled, "No second recording while transcribing")
                    XCTAssertFalse(canStartMeeting)
                default:
                    XCTAssertFalse(record.isEnabled, "Nothing to record with")
                }
                window.close()
            }
        }
        XCTAssertEqual(Set(historyHeights.values).count, 1, "The dictation bar must not grow over History: \(historyHeights)")
    }

    /// The dictation bar floats: History runs to the window's bottom edge
    /// behind it instead of ending above it, and the bar sits inside
    /// History's frame with a margin on every side.
    func testTheDictationBarFloatsOverHistory() throws {
        for (name, size) in Self.sizes {
            let window = try host(size: size)
            let list = window.frameInHost(try XCTUnwrap(window.historyScrollView))
            let record = window.frameInHost(try XCTUnwrap(window.recordButton))
            XCTAssertEqual(list.maxY, window.host.bounds.height, accuracy: 0.5, "History reaches the window's bottom edge at \(name)")
            XCTAssertTrue(list.contains(record), "The record control floats over History at \(name)")
            XCTAssertLessThanOrEqual(record.maxY, window.host.bounds.height - DictationDock.margin, "The bar keeps its margin from the window edge at \(name)")
            XCTAssertLessThanOrEqual(record.maxX, window.host.bounds.width - DictationDock.margin, "and from its side at \(name)")
            window.close()
        }
    }

    /// At the width the window opens with, the mode row keeps its label and
    /// its segments at their own width with room to spare, so choosing a
    /// segment never flips the row to its narrower form. Narrow windows drop
    /// the label and let the segments fill the bar.
    func testModeRowKeepsItsLabelAtTheOpeningWidthWithRoomToSpare() throws {
        func segments(width: CGFloat) throws -> (frame: CGRect, natural: CGFloat) {
            let dock = OffscreenHost(
                DictationDock(status: .ready, shortcut: "⌃ / fn", writingSelection: .constant(.builtIn(.everyday)),
                              onLearn: {}, microphones: [MainWindowFixtures.microphone],
                              currentMicrophoneID: MainWindowFixtures.microphone.id, onSelectMicrophone: { _ in }, onRecord: {}),
                size: CGSize(width: width, height: 140)
            )
            let control = try XCTUnwrap(dock.segmentedControls.first)
            return withExtendedLifetime(dock) { (dock.frameInHost(control), control.fittingSize.width) }
        }
        for width in [CGFloat(560), 550] {
            let row = try segments(width: width)
            XCTAssertEqual(row.frame.width, row.natural, accuracy: 1, "The segments keep their own width at \(width)")
            XCTAssertGreaterThan(row.frame.minX, 90, "The Dictation mode label sits before them at \(width)")
        }
        let narrow = try segments(width: 440)
        XCTAssertLessThan(narrow.frame.minX, 40, "No label in a narrow window")
        XCTAssertGreaterThan(narrow.frame.width, 300, "The segments fill the bar")
    }

    /// The bar is a sibling of History, not part of it: when History reloads,
    /// as it does after every dictation, the bar keeps the same controls, so
    /// a menu that is open, keyboard focus, and the record control's state
    /// are not thrown away.
    func testAHistoryRefreshKeepsTheDictationBarsControls() async throws {
        for recordings in [[], MainWindowFixtures.history()] {
            let window = try host(recordings, appStorage: .standard)
            let picker = try XCTUnwrap(window.segmentedControls.first)
            let record = try XCTUnwrap(window.recordButton)

            NotificationCenter.default.post(name: RecordingStore.recordingsDidUpdateNotification, object: nil)
            window.viewModel.refreshHistory()
            for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
            window.settle()

            let name = recordings.isEmpty ? "an empty History" : "a History with rows"
            XCTAssertTrue(window.segmentedControls.first === picker, "The mode picker survives a refresh of \(name)")
            XCTAssertNotNil(picker.window, "and is still in the window")
            XCTAssertTrue(window.recordButton === record, "The record control survives a refresh of \(name)")
            window.close()
        }
    }

    /// The README preview: the window listening under Auto, with three
    /// successful synthetic dictations and their time saved. It is rendered
    /// from the real view like every other state here; nothing is recorded.
    func testReadmePreviewListensUnderAutoAboveSuccessfulDictations() throws {
        try CustomCleanupFilterStore.upsert(MainWindowFixtures.calculus, in: appStorage)
        try CustomCleanupFilterStore.upsert(MainWindowFixtures.standup, in: appStorage)
        FilterAutoSettings.setEnabled(true, in: appStorage)
        let history = MainWindowFixtures.readmeHistory()
        for scheme in [ColorScheme.light, .dark] {
            let window = try MainWindowHost(
                recordings: history.recordings, sources: history.sources, size: CGSize(width: 560, height: 460), scheme: scheme,
                appStorage: appStorage, pasteboard: pasteboard.name
            ) { ScriptedRecordingViewModel(transcriptionService: $0, transcriptionQueue: $1, recordingStore: $2) }
            let model = try XCTUnwrap(window.viewModel as? ScriptedRecordingViewModel)
            model.scriptedRecording = true
            model.updateRecorderState(isRecording: true, isConnecting: false)
            window.settle { model.speakingSummary.counted.count == 3 }
            XCTAssertEqual(model.speakingSummary.counted.count, 3, "Every row is a measured live dictation")
            XCTAssertTrue(model.recordings.allSatisfy { $0.speaking?.sample != nil })
            save(try window.render(), name: "readme-listening-\(scheme.label)")
            window.assertHistoryStaysBelowTheToolbar()
            window.assertControlsFitWithoutOverlapping()
            XCTAssertTrue(try XCTUnwrap(window.recordButton).isEnabled, "Stop stays available while listening")
            XCTAssertFalse(window.window.isVisible, "Visual verification must stay offscreen")
            window.close()
        }
    }

    func testEmptySearchAndNoResultStates() throws {
        for scheme in [ColorScheme.light, .dark] {
            let empty = try host([], scheme: scheme)
            XCTAssertNil(empty.historyScrollView, "An empty History shows its empty state, not a list")
            save(try empty.render(), name: "state-empty-\(scheme.label)")
            empty.close()

            let window = try host(scheme: scheme)
            window.search("review")
            XCTAssertEqual(window.viewModel.recordings.map(\.fileName), ["fixture-b.wav", "fixture-f.wav"],
                           "The search field filters History through the store")
            save(try window.render(), name: "state-search-\(scheme.label)")

            window.search("zebra")
            XCTAssertEqual(window.viewModel.recordings.count, 0)
            XCTAssertNil(window.historyScrollView)
            save(try window.render(), name: "state-no-results-\(scheme.label)")

            window.search("")
            XCTAssertEqual(window.viewModel.recordings.count, MainWindowFixtures.history().count, "Clearing search restores History")
            window.close()
        }
    }

    func testRecoveryQueueCustomFiltersAndInputMonitoringRender() throws {
        let failed = try MainWindowFixtures.failedWithAudio()
        fixtureAudio.append(failed.url)
        CustomCleanupFilterStore.save([CustomCleanupFilterStore.examples[0], CustomCleanupFilterStore.examples[2]], to: appStorage)
        for scheme in [ColorScheme.light, .dark] {
            let window = try host([failed, MainWindowFixtures.queued()] + MainWindowFixtures.history(),
                                  scheme: scheme,
                                  permissions: PermissionsManager(microphone: true, accessibility: true, inputMonitoring: false))
            save(try window.render(), name: "state-recovery-filters-notice-\(scheme.label)")
            window.assertControlsFitWithoutOverlapping()
            window.close()
        }
        let minimum = try host([failed] + MainWindowFixtures.history(), size: Self.sizes[1].size,
                               permissions: PermissionsManager(microphone: true, accessibility: true, inputMonitoring: false))
        save(try minimum.render(), name: "state-recovery-filters-notice-minimum-light")
        minimum.assertControlsFitWithoutOverlapping()
        minimum.close()
    }

    // MARK: - Text

    func testLongTranscriptIsWhollySelectableExpandsAndCopiesInFull() throws {
        for (name, size) in Self.sizes {
            let window = try host(size: size)
            let essay = try XCTUnwrap(window.textField(containing: "The French Revolution began"))
            XCTAssertEqual(essay.stringValue, MainWindowFixtures.longEssay, "Collapsed rows still hold every word")
            XCTAssertTrue(essay.isSelectable, "The transcript can be selected")
            let collapsedHeight = essay.frame.height

            let toggles = window.expandButtons
            XCTAssertEqual(toggles.count, 1, "Only the long transcript offers Show full text at \(name)")
            toggles.first?.performClick(nil)
            window.settle()
            let expanded = try XCTUnwrap(window.textField(containing: "The French Revolution began"))
            XCTAssertGreaterThan(expanded.frame.height, collapsedHeight + 30, "Show full text reveals the hidden lines at \(name)")
            if name == "screenshot" { save(try window.render(), name: "state-long-expanded-light") }

            let copy = try XCTUnwrap(window.rowButton(below: expanded), "The row shows a Copy button")
            copy.performClick(nil)
            XCTAssertEqual(pasteboard.string(forType: .string), MainWindowFixtures.longEssay, "Copy takes the whole transcript")
            pasteboard.clearContents()
            window.close()
        }
    }

    func testShortTranscriptsNeedNoExpansion() throws {
        let window = try host()
        let short = try XCTUnwrap(window.textField(containing: "Move the design review"))
        XCTAssertEqual(short.stringValue, "Move the design review to Thursday afternoon.")
        XCTAssertLessThan(short.frame.height, 24, "One line")
        try XCTUnwrap(window.rowButton(below: short)).performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "Move the design review to Thursday afternoon.")
        window.close()
    }

    // MARK: - Actions

    func testRowActionsFollowTheRecordingState() {
        func actions(_ status: RecordingStatus, text: String = "Words", audio: Bool = true, playing: Bool = false) -> HistoryRowActions {
            HistoryRowActions(
                recording: Recording(id: UUID(), timestamp: Date(), fileName: "x.wav", transcription: text,
                                     duration: 2, status: status, progress: status == .completed ? 1 : 0.4),
                hasAudio: audio, isPlaying: playing
            )
        }
        func enabled(_ a: HistoryRowActions) -> [HistoryRowAction] { HistoryRowAction.allCases.filter(a.isEnabled) }

        XCTAssertEqual(enabled(actions(.completed)), [.play, .copy, .regenerate, .delete])
        XCTAssertEqual(enabled(actions(.completed, audio: false)), [.copy, .delete], "No playback or Regenerate without audio")
        XCTAssertEqual(enabled(actions(.completed, text: "")), [.play, .regenerate, .delete], "Nothing to copy")
        XCTAssertEqual(enabled(actions(.failed)), [.regenerate, .delete], "A failure keeps Regenerate and Delete")
        XCTAssertEqual(enabled(actions(.failed, audio: false)), [.delete])
        for pending in [RecordingStatus.pending, .converting, .transcribing] {
            XCTAssertEqual(enabled(actions(pending)), [.copy, .delete], "\(pending) is still being written")
        }
        XCTAssertEqual(enabled(actions(.pending, text: "In queue...")), [.delete], "The queue placeholder is not a transcript")

        XCTAssertEqual(actions(.completed).visible, [.copy])
        XCTAssertEqual(actions(.failed).visible, [.regenerate], "Recovery is one click away")
        XCTAssertEqual(actions(.failed, audio: false).visible, [], "Only the actions menu, which keeps Delete")
        XCTAssertEqual(actions(.transcribing, text: "").visible, [], "Nothing to copy yet")
        XCTAssertEqual(actions(.completed, playing: true).visible, [.play, .copy], "Stop shows while playing")
        XCTAssertEqual(actions(.completed, playing: true).title(.play), "Stop Playback")

        let titles = HistoryRowAction.allCases.map { actions(.completed).title($0) }
        XCTAssertEqual(titles, ["Play Recording", "Copy Transcript", "Regenerate Transcript", "Delete Recording"])
        for action in HistoryRowAction.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: actions(.completed).systemImage(action), accessibilityDescription: nil))
        }
    }

    func testToolbarButtonsCallTheirActions() throws {
        var calls: [String] = []
        func toolbar(recording: Bool = false, inProgress: Bool = false, meetingAvailable: Bool = true) -> some View {
            MainToolbar(
                search: HistorySearch(onQuery: { _ in }), meetingLabel: recording ? "Stop & save meeting" : "Start meeting",
                isMeetingRecording: recording, isMeetingInProgress: inProgress,
                isMeetingAvailable: meetingAvailable, canDeleteAll: true,
                onMeeting: { calls.append("meeting") }, onDeleteAll: { calls.append("delete") }, onSettings: { calls.append("settings") }
            )
        }
        let idle = OffscreenHost(toolbar(), size: CGSize(width: 560, height: 40))
        XCTAssertEqual(idle.buttons.count, 1, "Only Settings is a button; meetings start from More")
        XCTAssertEqual(idle.popUps.count, 1, "More opens a menu")
        XCTAssertEqual(idle.searchFields.first?.placeholderString, "Search History")
        let idleToolbar = MainToolbar(search: HistorySearch(onQuery: { _ in }), meetingLabel: "Start meeting", isMeetingRecording: false,
                                      isMeetingAvailable: true, canDeleteAll: true, onMeeting: {}, onDeleteAll: {}, onSettings: {})
        XCTAssertEqual(idleToolbar.moreMenuItems, [.init(title: "Start Meeting Recording…", isEnabled: true),
                                                   .init(title: "Delete All Recordings…", isEnabled: true)])
        idle.buttons.forEach { $0.performClick(nil) }
        XCTAssertEqual(calls, ["settings"], "Delete All is only reachable through the More menu and its confirmation")

        calls = []
        let recording = OffscreenHost(toolbar(recording: true, inProgress: true), size: CGSize(width: 560, height: 40))
        let buttons = recording.buttons.sorted { recording.frameInHost($0).minX < recording.frameInHost($1).minX }
        XCTAssertEqual(buttons.count, 2, "A running meeting puts its stop button in the toolbar")
        buttons.forEach { $0.performClick(nil) }
        XCTAssertEqual(calls, ["meeting", "settings"])
        let recordingToolbar = MainToolbar(search: HistorySearch(onQuery: { _ in }), meetingLabel: "Stop & save meeting", isMeetingRecording: true,
                                           isMeetingInProgress: true, isMeetingAvailable: true, canDeleteAll: false,
                                           onMeeting: {}, onDeleteAll: {}, onSettings: {})
        XCTAssertEqual(recordingToolbar.moreMenuItems.map(\.isEnabled), [false, false], "No second meeting; nothing to delete")

        let saving = OffscreenHost(toolbar(inProgress: true, meetingAvailable: false), size: CGSize(width: 560, height: 40))
        let stop = try XCTUnwrap(saving.buttons.min { saving.frameInHost($0).minX < saving.frameInHost($1).minX })
        XCTAssertFalse(stop.isEnabled, "Nothing to stop while the meeting saves")
        withExtendedLifetime((idle, recording, saving)) {}
    }

    func testDockLearnAndRecordRouteAndModePickerSaves() throws {
        var calls: [String] = []
        let dock = OffscreenHost(
            DictationDock(status: .ready, shortcut: "⌃ / fn", writingSelection: .constant(.builtIn(.homework)),
                          onLearn: { calls.append("learn") },
                          microphones: [MainWindowFixtures.microphone], currentMicrophoneID: MainWindowFixtures.microphone.id,
                          onSelectMicrophone: { _ in calls.append("microphone") },
                          onRecord: { calls.append("record") }),
            size: CGSize(width: 560, height: 120)
        )
        let buttons = dock.buttons.sorted { dock.frameInHost($0).minY < dock.frameInHost($1).minY }
        XCTAssertEqual(buttons.count, 2, "Learn and the record button")
        buttons.forEach { $0.performClick(nil) }
        XCTAssertEqual(calls, ["learn", "record"])
        XCTAssertEqual(dock.popUps.count, 1, "The microphone menu sits beside the record button")
        XCTAssertEqual(dock.segmentedControls.first?.segmentCount, 4, "Homework, Technical, Everyday, Writing")

        // In the whole window the segmented control writes the mode dictation uses.
        let window = try host()
        let picker = try XCTUnwrap(window.segmentedControls.first)
        XCTAssertEqual(picker.selectedSegment, 0, "Homework")
        picker.selectedSegment = 1
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        window.settle()
        XCTAssertEqual(CustomCleanupFilterStore.currentSnapshot().mode, .technical)
        window.close()
        withExtendedLifetime(dock) {}
    }

    /// Every switch in the dictation bar reaches the next dictation and
    /// survives a reload. The model keeps spoken numbers as words, as Nova
    /// Micro did in the user's Homework dictations, so Homework's digits come
    /// from WorkFlow itself.
    func testEveryModeSwitchReachesTheNextDictationAndSurvivesReload() async throws {
        let store = try RecordingStore(database: DatabaseQueue(), recordingsDirectory: Recording.recordingsDirectory,
                                       cancelQueuedRecording: { _ in }, stopPlayback: { _ in })
        let engine = MainWindowFixtures.SpokenWords()
        let model = MainWindowFixtures.WordKeepingCleanup()
        let gate = LatestDictationGate()
        let indicator = IndicatorViewModel(
            latestDictationGate: gate,
            transcriptionService: TranscriptionService(engine: engine),
            recordingStore: store,
            cleanupPipeline: TranscriptCleanupPipeline(
                isEnabled: { true }, providerResolver: { model }, vocabularyProvider: { [] },
                appRuleProvider: { _ in nil }, bedrockBudgetProvider: { nil }, failureRecorder: { _ in }
            ),
            delivery: { _ in .pasteSent }
        )
        defer { indicator.cleanup() }
        let spoken = "fifteen percent of the one hundred five students finished by twenty twenty six"
        let words = "Fifteen percent of the one hundred five students finished by twenty twenty six."

        let window = try host([], appStorage: .standard)
        let picker = try XCTUnwrap(window.segmentedControls.first)
        let order: [CleanupMode] = [.homework, .technical, .everyday, .writing]
        XCTAssertEqual((0..<picker.segmentCount).map { picker.label(forSegment: $0) }, order.map(\.displayName))
        for mode in [CleanupMode.writing, .homework, .technical, .everyday, .homework] {
            picker.selectedSegment = try XCTUnwrap(order.firstIndex(of: mode))
            XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
            window.settle()
            XCTAssertEqual(CustomCleanupFilterStore.currentSnapshot().mode, mode)

            let audio = FileManager.default.temporaryDirectory.appendingPathComponent("MainWindowLayoutTests-\(UUID().uuidString).wav")
            try Data("synthetic audio".utf8).write(to: audio)
            engine.spoken[audio] = spoken
            let saved = try await store.fetchRecordings(limit: 50, offset: 0).count
            await indicator.finishDictation(audioAt: audio, generation: gate.begin(), recordingStartedAt: Date())
            var rows: [Recording] = []
            for _ in 0..<200 {
                rows = try await store.fetchRecordings(limit: 50, offset: 0)
                if rows.count > saved { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let row = try XCTUnwrap(rows.first { !fixtureAudio.contains($0.url) }, "History saved the \(mode) dictation")
            fixtureAudio.append(row.url)
            XCTAssertEqual(row.cleanupMode, mode)
            let evidence = try await store.dictationSource(for: row.id)
            XCTAssertEqual(evidence?.selectedMode, mode)
            XCTAssertTrue(try XCTUnwrap(model.prompts.last).contains("\n\(mode.displayName) mode"), "\(mode) prompt")
            XCTAssertEqual(row.transcription, mode == .homework ? "15% of the 105 students finished by 2026." : words, "\(mode)")
        }
        window.close()

        let reopened = try host([], appStorage: .standard)
        defer { reopened.close() }
        XCTAssertEqual(try XCTUnwrap(reopened.segmentedControls.first).selectedSegment, 0, "Homework after reload")
        XCTAssertEqual(CustomCleanupFilterStore.currentSnapshot().mode, .homework)
    }

    /// The picker's hidden "Dictation mode" title already names it for
    /// VoiceOver; a second label made it read the name twice. The group is
    /// not called "Writing mode", which read as the Writing option.
    func testDockDictationModeSpeaksItsNameOnce() {
        for filters in [[], [CustomCleanupFilterStore.examples[0]]] {
            let names = AccessibilityTree.withSwiftUITree {
                let dock = OffscreenHost(
                    DictationDock(status: .ready, shortcut: "⌃ / fn", writingSelection: .constant(.builtIn(.homework)),
                                  customFilters: filters, onRecord: {}),
                    size: CGSize(width: 560, height: 120)
                )
                return AccessibilityTree.labels(in: dock.host, roles: [.popUpButton, .radioGroup])
            }
            XCTAssertEqual(names, ["Dictation mode"], filters.isEmpty ? "Segmented modes" : "Menu with custom filters")
        }
    }

    func testShortcutHintFollowsTheSavedShortcut() {
        let standard = UserDefaults.standard
        XCTAssertEqual(ContentView.shortcutDescription(), "⌃ / fn")
        XCTAssertEqual(DictationDockStatus.ready.detail(shortcut: ContentView.shortcutDescription()), "Press ⌃ / fn to dictate anywhere")
        standard.set(ModifierKey.none.rawValue, forKey: "secondaryModifierOnlyHotkey")
        XCTAssertEqual(ContentView.shortcutDescription(), "⌃")
        standard.set(MouseButton.middle.rawValue, forKey: "mouseButtonHotkey")
        XCTAssertEqual(ContentView.shortcutDescription(), MouseButton.middle.shortSymbol)
    }

    func testDayGroupingKeepsOrderAndLabelsDays() {
        // The fixture spans 27 hours before `now`, so it is anchored at midday:
        // run just after midnight, rows from Date() would fall two days back.
        let midday = Calendar.current.date(byAdding: .hour, value: 12, to: Calendar.current.startOfDay(for: Date()))!
        let rows = MainWindowFixtures.history(now: midday)
        let days = HistoryDay.group(rows)
        XCTAssertEqual(days.map(\.title), ["Today", "Yesterday"])
        XCTAssertEqual(days.flatMap(\.recordings).map(\.id), rows.map(\.id), "Grouping never reorders or drops a row")
        XCTAssertEqual(Set(days.map(\.id)).count, days.count)
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String) {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG encoding failed for \(name)")
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = MainWindowHost.renderDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

/// Stands in for a live microphone session, which only the recorder can own.
private final class ScriptedRecordingViewModel: ContentViewModel {
    var scriptedRecording = false
    override var isRecording: Bool { scriptedRecording }
}

/// AppKit views behind a hosted SwiftUI tree, found without accessibility clients.
@MainActor
protocol HostedControls {
    var host: NSView { get }
}

extension HostedControls {
    func allViews(_ view: NSView? = nil) -> [NSView] {
        let root = view ?? host
        return [root] + root.subviews.flatMap { allViews($0) }
    }

    func frameInHost(_ view: NSView) -> CGRect {
        let frame = view.convert(view.bounds, to: host)
        return host.isFlipped ? frame : CGRect(x: frame.minX, y: host.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Borderless SwiftUI buttons, which AppKit backs with real buttons.
    var buttons: [NSButton] {
        allViews().compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) && String(describing: type(of: $0)).contains("SwiftUI") }
    }
    var popUps: [NSPopUpButton] { allViews().compactMap { $0 as? NSPopUpButton } }
    var searchFields: [NSSearchField] { allViews().compactMap { $0 as? NSSearchField } }
    var segmentedControls: [NSSegmentedControl] { allViews().compactMap { $0 as? NSSegmentedControl } }
}

/// One production component alone in an offscreen window.
@MainActor
final class OffscreenHost<Content: View>: HostedControls {
    let window: NSWindow
    let host: NSView

    init(_ content: Content, size: CGSize) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        window.contentView = hosting
        host = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
    }
}

/// A hosting view that counts its layout passes. SwiftUI lays its hosting
/// view out once for every frame it draws, so the count says how often a
/// window was redrawn without timing anything.
final class LayoutCountingHostingView<Content: View>: NSHostingView<Content> {
    private(set) var layoutPasses = 0

    override func layout() {
        layoutPasses += 1
        super.layout()
    }
}

/// A `ContentView` in an offscreen window shaped like the app's main window.
@MainActor
final class MainWindowHost: HostedControls {
    /// `WF_RENDER_DIR` (passed as `TEST_RUNNER_WF_RENDER_DIR`) collects renders for review.
    static var renderDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["WF_RENDER_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("WorkFlowMainWindowRenders", isDirectory: true)
    }

    let window: NSWindow
    let host: NSView
    let viewModel: ContentViewModel
    let store: RecordingStore
    /// How many times SwiftUI has laid the window out, which it does once
    /// for every frame it draws.
    let layoutPasses: () -> Int

    init(
        recordings: [Recording],
        sources: [DictationSource] = [],
        size: CGSize,
        scheme: ColorScheme,
        appStorage: UserDefaults,
        pasteboard: NSPasteboard.Name = NSPasteboard.Name("MainWindowHost-unused"),
        permissions: PermissionsManager? = nil,
        windowOnScreen: Bool? = true,
        viewModel makeViewModel: ((TranscriptionService, TranscriptionQueue, RecordingStore) -> ContentViewModel)? = nil
    ) throws {
        store = try RecordingStore(
            database: DatabaseQueue(),
            recordingsDirectory: Recording.recordingsDirectory,
            cancelQueuedRecording: { _ in },
            stopPlayback: { _ in }
        )
        for recording in recordings {
            if let source = sources.first(where: { $0.recordingID == recording.id }) {
                store.addRecording(recording, source: source)
            } else {
                store.addRecording(recording)
            }
        }
        let transcription = TranscriptionService(engine: ControlledTranscriptionEngine { _ in })
        let queue = TranscriptionQueue(
            transcriptionService: transcription,
            recordingStore: store,
            cleanupPipeline: TranscriptCleanupPipeline(
                isEnabled: { false },
                providerResolver: { throw CleanupProviderError.missingCredential("none") },
                vocabularyProvider: { [] },
                appRuleProvider: { _ in nil },
                bedrockBudgetProvider: { nil },
                filterProvider: { .builtIn(.homework) },
                failureRecorder: { _ in }
            )
        )
        let model = makeViewModel?(transcription, queue, store)
            ?? ContentViewModel(transcriptionService: transcription, transcriptionQueue: queue, recordingStore: store)
        viewModel = model

        let content = ContentView(
            viewModel: model,
            permissionsManager: permissions ?? PermissionsManager(microphone: true, accessibility: true, inputMonitoring: true)
        )
        .tint(ThemePalette.controlTint)
        .environment(\.colorScheme, scheme)
        .environment(\.transcriptPasteboard, pasteboard)
        // The window is never shown. Renders draw it as it looks on screen;
        // nil lets the window answer for itself, which is "not on screen".
        .environment(\.windowOnScreenOverride, windowOnScreen)
        .defaultAppStorage(appStorage)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let hosting = LayoutCountingHostingView(rootView: content)
        layoutPasses = { hosting.layoutPasses }
        window.contentView = hosting
        host = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        settle { model.recordings.count == recordings.count && !model.isLoadingMore }
    }

    /// Lets SwiftUI and the History loader finish without showing anything.
    func settle(timeout: TimeInterval = 3, until condition: () -> Bool = { true }) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded()
        } while !condition() && Date() < deadline
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    /// Types into the toolbar's search field the way AppKit reports typing,
    /// then waits out the search debounce and the store query.
    func search(_ query: String) {
        guard let field = searchFields.first else { return XCTFail("No search field") }
        field.stringValue = query
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        let previous = viewModel.recordings.map(\.id)
        settle(timeout: 2) { viewModel.recordings.map(\.id) != previous && !viewModel.isLoadingMore }
        settle()
    }

    var historyScrollView: NSScrollView? {
        allViews().compactMap { $0 as? NSScrollView }.first { !($0.documentView is NSTextView) && frameInHost($0).height > 60 }
    }

    /// Selectable transcript text, which SwiftUI backs with a text field.
    func textField(containing prefix: String) -> NSTextField? {
        allViews().compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix(prefix) && !($0 is NSSearchField) }
    }

    /// Show full text / Show less: the only wide borderless buttons in History.
    var expandButtons: [NSButton] {
        guard let list = historyScrollView else { return [] }
        return buttons.filter { $0.isDescendant(of: list) && $0.frame.width > 40 }
    }

    /// The visible row button (Copy, or Regenerate after a failure) on the
    /// metadata line just under a transcript.
    func rowButton(below text: NSView) -> NSButton? {
        guard let list = historyScrollView else { return nil }
        let textBottom = frameInHost(text).maxY
        return buttons
            .filter { $0.isDescendant(of: list) && $0.frame.width <= 30 && frameInHost($0).minY >= textBottom - 4 }
            .min { frameInHost($0).minY < frameInHost($1).minY }
    }

    private var toolbarButtons: [NSButton] {
        buttons.filter { frameInHost($0).maxY <= WFChrome.titleBarHeight }
    }

    /// The toolbar's stop-meeting button, present only while a meeting runs.
    var meetingStopButton: NSButton? { toolbarButtons.count > 1 ? toolbarButtons.min { frameInHost($0).minX < frameInHost($1).minX } : nil }

    /// The record control: the one button with its frame, wherever the
    /// floating dictation bar puts it.
    var recordButton: NSButton? {
        buttons.first {
            abs($0.frame.width - WFRecordControl.size) < 1 && abs($0.frame.height - WFRecordControl.size) < 1
        }
    }

    /// macOS 26 stretches a scroll view that touches the toolbar band up under
    /// it and lays a glass edge over the toolbar row; History must stay below.
    func assertHistoryStaysBelowTheToolbar(file: StaticString = #filePath, line: UInt = #line) {
        guard let scrollView = historyScrollView else { return XCTFail("No History list", file: file, line: line) }
        XCTAssertGreaterThanOrEqual(frameInHost(scrollView).minY, WFChrome.titleBarHeight, "History reaches under the toolbar", file: file, line: line)
        XCTAssertEqual(scrollView.contentInsets.top, 0, "History is inset for a toolbar it should not sit under", file: file, line: line)
        let backdrops = scrollView.subviews.filter { String(describing: type(of: $0)).contains("Backdrop") }
        XCTAssertTrue(backdrops.isEmpty, "A glass edge would cover the toolbar row", file: file, line: line)
    }

    /// Toolbar and dictation-bar controls are wholly inside the window, clear
    /// of the traffic lights, and never on top of each other.
    func assertControlsFitWithoutOverlapping(file: StaticString = #filePath, line: UInt = #line) {
        let list = historyScrollView
        let chrome: [NSView] = (buttons as [NSView]) + popUps + searchFields + segmentedControls
        let controls = chrome.filter { view in list.map { !view.isDescendant(of: $0) } ?? true }
        let frames = controls.map { frameInHost($0) }
        XCTAssertGreaterThanOrEqual(frames.count, 6, "Search, More, Settings, modes, microphone, record", file: file, line: line)
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(controls[index]) at \(frame) is clipped", file: file, line: line)
            if frame.maxY <= WFChrome.titleBarHeight {
                XCTAssertGreaterThanOrEqual(frame.minX, WFChrome.trafficLightInset - 0.5, "\(controls[index]) sits on the traffic lights", file: file, line: line)
            }
            for other in frames[(index + 1)...] {
                let overlap = frame.intersection(other)
                XCTAssertTrue(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5,
                              "\(controls[index]) at \(frame) overlaps a control at \(other)", file: file, line: line)
            }
        }
        if let search = searchFields.first {
            XCTAssertGreaterThanOrEqual(search.frame.width, 100, "Search stays usable", file: file, line: line)
        }
    }

    /// The hosting view's drawing plus the window's traffic lights, which
    /// live in the title bar rather than in the content.
    func render() throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw XCTSkip("No bitmap for the hosting view")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        // Their layers draw just the discs; a view snapshot would add a square backing.
        let context = NSGraphicsContext.current!.cgContext
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), let layer = button.layer else { continue }
            button.display()
            let frame = button.convert(button.bounds, to: nil)
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.minY)
            if layer.isGeometryFlipped == false && button.isFlipped {
                context.translateBy(x: 0, y: frame.height)
                context.scaleBy(x: 1, y: -1)
            }
            layer.render(in: context)
            context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}

/// Synthetic dictations only; none come from a real History.
enum MainWindowFixtures {
    static let microphone = MicrophoneService.AudioDevice(id: "fixture-microphone", name: "Fixture Microphone", manufacturer: nil, isBuiltIn: true)

    /// Returns the words "spoken" into each synthetic audio file.
    final class SpokenWords: TranscriptionEngine {
        let isModelLoaded = true
        let engineName = "Spoken words fixture"
        var spoken: [URL: String] = [:]

        func initialize() async throws {}
        func getSupportedLanguages() -> [String] { ["en"] }
        func cancelTranscription() {}
        func transcribeAudio(url: URL, settings: OpenSuperWhisper.Settings) async throws -> String { spoken[url] ?? "" }
    }

    /// A cleanup model that keeps spoken numbers as words whatever its prompt
    /// says; it only capitalizes and ends the sentence. The real guard checks it.
    final class WordKeepingCleanup: TranscriptCleanupProviding {
        let providerID: CleanupProviderID = .ollama
        private(set) var prompts: [String] = []

        func clean(transcript: String, systemPrompt: String, filter: CleanupFilterSnapshot) async throws -> CleanupProviderResult {
            prompts.append(systemPrompt)
            var text = transcript.prefix(1).uppercased() + transcript.dropFirst()
            if let last = text.last, !".!?".contains(last) { text += "." }
            return CleanupProviderResult(
                text: try CleanupGuard.postprocess(text, source: transcript, mode: filter.mode, allowsNumberFormatting: filter.allowsNumberFormatting),
                inputTokens: nil, outputTokens: nil, modelID: "word-keeping"
            )
        }
    }

    static func history(now: Date = Date()) -> [Recording] {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        return [
            Recording(id: UUID(), timestamp: ago(40), fileName: "fixture-a.wav",
                      transcription: "Okay so", duration: 2, status: .completed, progress: 1,
                      cleanupSource: .rawFallback, cleanupRequested: true),
            Recording(id: UUID(), timestamp: ago(95), fileName: "fixture-b.wav",
                      transcription: "Move the design review to Thursday afternoon.", duration: 3, status: .completed, progress: 1,
                      cleanupSource: .rawFallback, cleanupRequested: true),
            Recording(id: UUID(), timestamp: ago(210), fileName: "fixture-c.wav",
                      transcription: "Let's ship the smaller fix first and test the rest tomorrow.", duration: 4, status: .completed, progress: 1,
                      cleanupSource: .bedrock, cleanupInputTokens: 212, cleanupOutputTokens: 31,
                      cleanupModelID: "us.amazon.nova-micro-v1:0", cleanupRequested: true, cleanupMode: .technical,
                      rawTokenEstimate: 48, finalTokenEstimate: 29, tokenEstimatorID: LocalTokenEstimator.identifier),
            Recording(id: UUID(), timestamp: ago(330), fileName: "fixture-d.wav",
                      transcription: longEssay, duration: 91, status: .completed, progress: 1,
                      cleanupSource: .bedrock, cleanupInputTokens: 980, cleanupOutputTokens: 640,
                      cleanupModelID: "us.amazon.nova-micro-v1:0", cleanupRequested: true, cleanupMode: .homework,
                      rawTokenEstimate: 420, finalTokenEstimate: 352, tokenEstimatorID: LocalTokenEstimator.identifier),
            Recording(id: UUID(), timestamp: ago(3_900), fileName: "fixture-e.wav",
                      transcription: "Failed to transcribe: The speech model could not process the audio.", duration: 12, status: .failed, progress: 0),
            Recording(id: UUID(), timestamp: ago(5_400), fileName: "fixture-f.wav",
                      transcription: "We agreed to keep the current shortcuts, make failures easy to recover from, and review the first version on Friday.",
                      duration: 246, status: .completed, progress: 1, cleanupSource: .disabled,
                      title: "Product review", mode: .meeting),
            Recording(id: UUID(), timestamp: ago(93_600), fileName: "fixture-g.wav",
                      transcription: "Remind me to send the slides before lunch.", duration: 3, status: .completed, progress: 1,
                      cleanupSource: .budgetLimited, cleanupRequested: true),
            Recording(id: UUID(), timestamp: ago(97_200), fileName: "fixture-h.wav",
                      transcription: "Draft a short thank-you note to the team for staying late.", duration: 5, status: .completed, progress: 1,
                      cleanupSource: .bedrock, cleanupInputTokens: 150, cleanupOutputTokens: 40,
                      cleanupModelID: "us.amazon.nova-micro-v1:0", cleanupRequested: true, cleanupMode: .writing,
                      rawTokenEstimate: 61, finalTokenEstimate: 44, tokenEstimatorID: LocalTokenEstimator.identifier),
        ]
    }

    /// Three successful live dictations with their evidence, for the README
    /// preview: a Writing semicolon, a Technical request, and a saved filter
    /// Auto picked from two of its phrases. Every word is synthetic.
    static let calculus = CustomCleanupFilter(
        name: "Calculus", baseMode: .homework, instructions: "Write math notation compactly.", writesDigits: true,
        triggers: ["derivative", "integral", "limit"]
    )
    static let standup = CustomCleanupFilter(
        name: "Standup notes", baseMode: .writing, instructions: "Write short standup sentences."
    )

    static func readmeHistory(now: Date = Date()) -> (recordings: [Recording], sources: [DictationSource]) {
        let rows: [(seconds: TimeInterval, ago: TimeInterval, spoken: String, emitted: String, mode: CleanupMode,
                    filter: CustomCleanupFilter?, reason: FilterChoiceReason?, source: TranscriptCleanupOutcome.Source)] = [
            (6, 60, "the derivative of three x squared is six x and the integral brings it back",
             "The derivative of 3x² is 6x, and the integral brings it back.", .homework, calculus,
             .triggers(["derivative", "integral"]), .anthropic),
            (7, 300, "um add a retry with backoff to the upload client and uh cover it with a unit test",
             "Add a retry with backoff to the upload client and cover it with a unit test.", .technical, nil, nil, .openAI),
            (8, 900, "the draft is due friday i will send the outline tonight so we can review it together",
             "The draft is due Friday; I'll send the outline tonight so we can review it together.", .writing, nil, nil, .bedrock),
        ]
        var recordings: [Recording] = []
        var sources: [DictationSource] = []
        for row in rows {
            let id = UUID()
            let snapshot = row.filter.map { CleanupFilterSnapshot(filter: $0) } ?? .builtIn(row.mode)
            recordings.append(Recording(
                id: id, timestamp: now.addingTimeInterval(-row.ago), fileName: "fixture-readme-\(id.uuidString).wav",
                transcription: row.emitted, duration: row.seconds, status: .completed, progress: 1,
                cleanupSource: row.source, cleanupInputTokens: row.source == .bedrock ? 212 : nil,
                cleanupOutputTokens: row.source == .bedrock ? 31 : nil,
                cleanupModelID: row.source == .bedrock ? "us.amazon.nova-micro-v1:0" : nil, cleanupRequested: true,
                cleanupMode: row.mode, cleanupFilterName: row.filter?.name, cleanupFilterInstructions: row.filter?.instructions,
                cleanupFilterWritesDigits: row.filter?.writesDigits ?? false, cleanupFilterReason: row.reason
            ))
            var source = DictationSource(
                recordingID: id, recordingStartedAt: now.addingTimeInterval(-row.ago - row.seconds),
                recognizerText: row.spoken, emittedText: row.emitted, insertedText: row.emitted, disposition: .pasteSent,
                filter: snapshot, filterReason: row.reason, cleanupSource: row.source, captureOrigin: .live, processingSeconds: 0.9,
                speechActivity: .measured
            )
            source.activeSpeechSeconds = row.seconds * 0.75
            sources.append(source)
        }
        return (recordings, sources)
    }

    /// A failed dictation whose audio was kept, so Regenerate is offered.
    static func failedWithAudio(now: Date = Date()) throws -> Recording {
        let recording = Recording(id: UUID(), timestamp: now.addingTimeInterval(-10), fileName: "fixture-failed-\(UUID().uuidString).wav",
                                  transcription: "Failed to transcribe: The speech model could not process the audio.",
                                  duration: 7, status: .failed, progress: 0)
        try FileManager.default.createDirectory(at: Recording.recordingsDirectory, withIntermediateDirectories: true)
        try Data([0]).write(to: recording.url)
        return recording
    }

    /// An imported lecture still in the queue.
    static func queued(now: Date = Date()) -> Recording {
        Recording(id: UUID(), timestamp: now.addingTimeInterval(-5), fileName: "fixture-queued.wav",
                  transcription: "", duration: 1_820, status: .transcribing, progress: 0.42,
                  sourceFileURL: "/fixtures/Biology lecture 12.m4a")
    }

    /// A long homework-style answer, the case that must never be clipped.
    static let longEssay = """
    The French Revolution began in 1789 when financial crisis, food shortages, and resentment of noble privilege pushed the Third Estate to declare itself the National Assembly. Within weeks the storming of the Bastille showed that ordinary Parisians would defend that claim by force.

    Over the next three years the Assembly abolished feudal dues, issued the Declaration of the Rights of Man and of the Citizen, and wrote a constitution that limited the king's power. Each reform raised a harder question: who counted as a citizen, and what should happen to a monarch who would not accept the new order?

    By 1792 war with Austria and Prussia, fear of betrayal, and pressure from the Paris sections turned the revolution toward a republic. The execution of Louis XVI in January 1793 ended any compromise and opened the period historians call the Terror.
    """
}

extension ColorScheme {
    var label: String { self == .dark ? "dark" : "light" }
}
