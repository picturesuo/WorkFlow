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
        permissions: PermissionsManager? = nil,
        viewModel: ((TranscriptionService, TranscriptionQueue, RecordingStore) -> ContentViewModel)? = nil
    ) throws -> MainWindowHost {
        try MainWindowHost(recordings: recordings, size: size, scheme: scheme, appStorage: appStorage,
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
                let meeting = try XCTUnwrap(window.meetingButton)
                switch state {
                case "ready":
                    XCTAssertTrue(record.isEnabled, "Start recording is available when ready")
                    XCTAssertTrue(meeting.isEnabled, "A meeting can start when ready")
                case "recording":
                    XCTAssertTrue(record.isEnabled, "Stop stays available while recording")
                    XCTAssertFalse(meeting.isEnabled, "No meeting over a dictation")
                case "transcribing":
                    XCTAssertFalse(record.isEnabled, "No second recording while transcribing")
                    XCTAssertFalse(meeting.isEnabled)
                default:
                    XCTAssertFalse(record.isEnabled, "Nothing to record with")
                }
                window.close()
            }
        }
        XCTAssertEqual(Set(historyHeights.values).count, 1, "The dictation bar must not grow over History: \(historyHeights)")
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

            let copy = try XCTUnwrap(window.rowButton(above: expanded), "The row shows a Copy button")
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
        try XCTUnwrap(window.rowButton(above: short)).performClick(nil)
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
        func toolbar(meetingAvailable: Bool) -> some View {
            MainToolbar(
                searchText: .constant(""), meetingLabel: "Start meeting", isMeetingRecording: false,
                isMeetingAvailable: meetingAvailable, canDeleteAll: true,
                onMeeting: { calls.append("meeting") }, onDeleteAll: { calls.append("delete") }, onSettings: { calls.append("settings") }
            )
        }
        let available = OffscreenHost(toolbar(meetingAvailable: true), size: CGSize(width: 560, height: 40))
        let buttons = available.buttons.sorted { available.frameInHost($0).minX < available.frameInHost($1).minX }
        XCTAssertEqual(buttons.count, 2, "Meeting and Settings are buttons; More is a menu")
        XCTAssertEqual(available.popUps.count, 1, "More opens a menu")
        XCTAssertEqual(available.searchFields.first?.placeholderString, "Search History")
        buttons.forEach { $0.performClick(nil) }
        XCTAssertEqual(calls, ["meeting", "settings"], "Delete All is only reachable through the More menu and its confirmation")

        let busy = OffscreenHost(toolbar(meetingAvailable: false), size: CGSize(width: 560, height: 40))
        let meeting = try XCTUnwrap(busy.buttons.min { busy.frameInHost($0).minX < busy.frameInHost($1).minX })
        XCTAssertFalse(meeting.isEnabled)
        withExtendedLifetime((available, busy)) {}
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

    /// The picker's hidden "Writing mode" title already names it for
    /// VoiceOver; a second label made it read "Writing mode, Writing mode".
    func testDockWritingModeSpeaksItsNameOnce() {
        for filters in [[], [CustomCleanupFilterStore.examples[0]]] {
            let names = AccessibilityTree.withSwiftUITree {
                let dock = OffscreenHost(
                    DictationDock(status: .ready, shortcut: "⌃ / fn", writingSelection: .constant(.builtIn(.homework)),
                                  customFilters: filters, onRecord: {}),
                    size: CGSize(width: 560, height: 120)
                )
                return AccessibilityTree.labels(in: dock.host, roles: [.popUpButton, .radioGroup])
            }
            XCTAssertEqual(names, ["Writing mode"], filters.isEmpty ? "Segmented modes" : "Menu with custom filters")
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
        let rows = MainWindowFixtures.history()
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

    init(
        recordings: [Recording],
        size: CGSize,
        scheme: ColorScheme,
        appStorage: UserDefaults,
        pasteboard: NSPasteboard.Name = NSPasteboard.Name("MainWindowHost-unused"),
        permissions: PermissionsManager? = nil,
        viewModel makeViewModel: ((TranscriptionService, TranscriptionQueue, RecordingStore) -> ContentViewModel)? = nil
    ) throws {
        store = try RecordingStore(
            database: DatabaseQueue(),
            recordingsDirectory: Recording.recordingsDirectory,
            cancelQueuedRecording: { _ in },
            stopPlayback: { _ in }
        )
        for recording in recordings {
            store.addRecording(recording)
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
        .defaultAppStorage(appStorage)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: content)
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
    /// metadata line just above a transcript.
    func rowButton(above text: NSView) -> NSButton? {
        guard let list = historyScrollView else { return nil }
        let textTop = frameInHost(text).minY
        return buttons
            .filter { $0.isDescendant(of: list) && $0.frame.width <= 30 && frameInHost($0).maxY <= textTop + 4 }
            .max { frameInHost($0).minY < frameInHost($1).minY }
    }

    private var toolbarButtons: [NSButton] {
        buttons.filter { frameInHost($0).maxY <= WFChrome.titleBarHeight }
    }

    var meetingButton: NSButton? { toolbarButtons.min { frameInHost($0).minX < frameInHost($1).minX } }

    var recordButton: NSButton? {
        let bottom = buttons.filter { frameInHost($0).minY > host.bounds.height - 60 }
        return bottom.max { frameInHost($0).maxX < frameInHost($1).maxX }
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
        XCTAssertGreaterThanOrEqual(frames.count, 7, "Search, meeting, More, Settings, modes, microphone, record", file: file, line: line)
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
