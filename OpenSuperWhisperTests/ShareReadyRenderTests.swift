import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// Offscreen renders of every recording state the window and the floating
/// indicator can show, with synthetic History only. Each PNG lands in
/// `WF_RENDER_DIR` so a reviewer can compare one revision with another.
/// Nothing opens the microphone, shows a window, reads the user's History,
/// or touches the general clipboard.
@MainActor
final class ShareReadyRenderTests: XCTestCase {
    private var appStorage: UserDefaults!
    private var suiteName: String!
    private var savedMicrophones: [MicrophoneService.AudioDevice] = []
    private var savedCurrentMicrophone: MicrophoneService.AudioDevice?
    private var fixtureAudio: [URL] = []
    /// The test host's own shortcut keys, pinned to Fn alone so every render
    /// shows the same hint whatever an earlier suite left behind.
    private static let shortcutKeys = ["modifierOnlyHotkey", "secondaryModifierOnlyHotkey", "mouseButtonHotkey", "modifierChordHotkey"]
    private var savedShortcut: [String: Any?] = [:]

    /// A speaking voice's recent levels, oldest first.
    static let speakingLevels: [CGFloat] = [0.18, 0.42, 0.66, 0.51, 0.83, 0.62, 0.74, 0.47, 0.58]

    override func setUp() {
        super.setUp()
        suiteName = "ShareReadyRenderTests-\(UUID().uuidString)"
        appStorage = UserDefaults(suiteName: suiteName)
        appStorage.set(ModifierKey.fn.rawValue, forKey: "modifierOnlyHotkey")
        CustomCleanupFilterStore.select(.builtIn(.everyday), in: appStorage)
        let standard = UserDefaults.standard
        for key in Self.shortcutKeys { savedShortcut[key] = standard.object(forKey: key) }
        standard.set(ModifierKey.fn.rawValue, forKey: "modifierOnlyHotkey")
        standard.set(ModifierKey.none.rawValue, forKey: "secondaryModifierOnlyHotkey")
        standard.set(MouseButton.none.rawValue, forKey: "mouseButtonHotkey")
        standard.set(ModifierChord.none.rawValue, forKey: "modifierChordHotkey")
        let microphones = MicrophoneService.shared
        savedMicrophones = microphones.availableMicrophones
        savedCurrentMicrophone = microphones.currentMicrophone
        microphones.availableMicrophones = [MainWindowFixtures.microphone]
        microphones.currentMicrophone = MainWindowFixtures.microphone
    }

    override func tearDown() {
        appStorage.removePersistentDomain(forName: suiteName)
        for (key, value) in savedShortcut {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        MicrophoneService.shared.availableMicrophones = savedMicrophones
        MicrophoneService.shared.currentMicrophone = savedCurrentMicrophone
        InputLevelMeter.shared.reset()
        for url in fixtureAudio { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    /// Idle, connecting, listening, busy, and error, in light and dark, at
    /// the size the window opens with. The record control keeps one frame
    /// and History keeps one height through all of them.
    func testMainWindowRecordingStates() throws {
        let failed = try MainWindowFixtures.failedWithAudio()
        fixtureAudio.append(failed.url)
        var recordFrames: [String: CGRect] = [:]
        var historyHeights: [String: CGFloat] = [:]
        for scheme in [ColorScheme.light, .dark] {
            for state in ["idle", "connecting", "listening", "busy", "error"] {
                if state == "error" {
                    MicrophoneService.shared.availableMicrophones = []
                    MicrophoneService.shared.currentMicrophone = nil
                }
                defer {
                    MicrophoneService.shared.availableMicrophones = [MainWindowFixtures.microphone]
                    MicrophoneService.shared.currentMicrophone = MainWindowFixtures.microphone
                    InputLevelMeter.shared.reset()
                }
                let rows = state == "error" ? [failed] + MainWindowFixtures.history() : MainWindowFixtures.history()
                let window = try MainWindowHost(recordings: rows, size: CGSize(width: 560, height: 720), scheme: scheme,
                                                appStorage: appStorage) {
                    RenderRecordingViewModel(transcriptionService: $0, transcriptionQueue: $1, recordingStore: $2)
                }
                let model = try XCTUnwrap(window.viewModel as? RenderRecordingViewModel)
                switch state {
                case "connecting":
                    model.state = .connecting
                case "listening":
                    model.scriptedRecording = true
                    model.updateRecorderState(isRecording: true, isConnecting: false)
                    Self.speakingLevels.forEach { InputLevelMeter.shared.push($0) }
                case "busy":
                    model.state = .decoding
                default:
                    break
                }
                // Let the record control's state animation finish, so the
                // render shows where each state rests, not a transition.
                window.settle()
                RunLoop.main.run(until: Date().addingTimeInterval(0.7))
                window.settle()
                ShareReadyRenders.save(try window.render(), name: "main-\(state)-\(scheme.label)", in: self)
                XCTAssertFalse(window.window.isVisible, "Renders stay offscreen")

                let record = try XCTUnwrap(window.recordButton)
                recordFrames[state] = window.frameInHost(record)
                historyHeights[state] = try XCTUnwrap(window.historyScrollView).frame.height
                XCTAssertEqual(record.isEnabled, state == "idle" || state == "listening",
                               "\(state): only ready and listening can be pressed")
                window.assertControlsFitWithoutOverlapping()
                window.close()
            }
        }
        XCTAssertEqual(Set(recordFrames.values.map { "\($0)" }).count, 1, "The record control never moves or resizes: \(recordFrames)")
        XCTAssertEqual(Set(historyHeights.values).count, 1, "The dock never grows over History: \(historyHeights)")
    }

    /// Every message the floating indicator can show, drawn over a light and
    /// a dark document so the capsule reads the way it will beside a caret.
    func testIndicatorStates() throws {
        let viewModel = IndicatorViewModel(
            latestDictationGate: LatestDictationGate(),
            transcriptionService: TranscriptionService(engine: ControlledTranscriptionEngine { _ in })
        )
        defer { viewModel.cleanup() }
        Self.speakingLevels.forEach { InputLevelMeter.shared.push($0) }
        viewModel.recordingStartedAt = Date().addingTimeInterval(-7)
        let states: [(String, RecordingState)] = [
            ("connecting", .connecting), ("listening", .recording), ("transcribing", .decoding), ("busy", .busy),
            ("no-microphone", .noMicrophone), ("transcription-failed", .transcriptionFailed), ("paste-failed", .pasteFailed),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, state) in states {
                viewModel.state = state
                let view = IndicatorWindow(viewModel: viewModel)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
                ShareReadyRenders.save(try ShareReadyRenders.render(AnyView(view), size: IndicatorWindow.windowSize, scheme: scheme),
                                       name: "indicator-\(name)-\(scheme.label)", in: self)
            }
        }
    }

    /// The record control alone in every phase, and listening at a quiet and
    /// a loud level, for a close look at the control itself.
    func testRecordControlSheet() throws {
        for scheme in [ColorScheme.light, .dark] {
            let sheet = HStack(spacing: 18) {
                ForEach(RecordButtonPhase.allCases, id: \.self) { phase in
                    RecordButtonFace(phase: phase, level: phase.isLive ? 0.7 : 0)
                }
                RecordButtonFace(phase: .listening, level: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemePalette.chromeBackground(scheme))
            let count = CGFloat(RecordButtonPhase.allCases.count + 1)
            let size = CGSize(width: count * WFRecordControl.size + (count - 1) * 18 + 40, height: 92)
            ShareReadyRenders.save(try ShareReadyRenders.render(AnyView(sheet), size: size, scheme: scheme),
                                   name: "record-control-\(scheme.label)", in: self)
        }
    }
}

/// Checks the record control and indicator with numbers rather than taste:
/// pixel colors, frames, contrast ratios, and motion with Reduce Motion on.
@MainActor
final class RecordControlTests: XCTestCase {
    override func tearDown() {
        InputLevelMeter.shared.reset()
        super.tearDown()
    }

    // MARK: Truthful state

    func testDockPhasesFollowTheRecorderNotTheRequest() {
        XCTAssertEqual(DictationDockStatus.ready.recordPhase, .ready)
        XCTAssertEqual(DictationDockStatus.connecting.recordPhase, .connecting, "An optimistic start is not listening yet")
        XCTAssertEqual(DictationDockStatus.recording(3).recordPhase, .listening)
        XCTAssertEqual(DictationDockStatus.meeting(60).recordPhase, .meeting)
        for working in [DictationDockStatus.transcribing, .loadingModel, .processingQueue, .savingMeeting] {
            XCTAssertEqual(working.recordPhase, .working)
            XCTAssertFalse(working.canActivate, "\(working) cannot be pressed")
        }
        XCTAssertEqual(DictationDockStatus.noMicrophone.recordPhase, .unavailable)
        XCTAssertFalse(DictationDockStatus.noMicrophone.canActivate)
        XCTAssertTrue(DictationDockStatus.meeting(1).canActivate, "A running meeting can be stopped from the dock")
        XCTAssertEqual(DictationDockStatus.meeting(1).recordAccessibilityLabel, "Stop & save meeting")
        XCTAssertEqual(DictationDockStatus.recording(1).recordAccessibilityLabel, "Stop recording")
        XCTAssertEqual(DictationDockStatus.ready.recordAccessibilityLabel, "Start recording")
        XCTAssertEqual(DictationDockStatus.recording(7).detail(shortcut: "fn"), "0:07 · Stop when you’re finished")
        XCTAssertEqual(DictationDockStatus.meeting(3_725).detail(shortcut: "fn"), "1:02:05 · Stop to save it to History")
    }

    func testLevelMeterMapsDecibelsAndReturnsToSilence() throws {
        XCTAssertEqual(InputLevelMeter.normalized(decibels: -160), 0)
        XCTAssertEqual(InputLevelMeter.normalized(decibels: -55), 0)
        XCTAssertEqual(InputLevelMeter.normalized(decibels: -10), 1)
        XCTAssertEqual(InputLevelMeter.normalized(decibels: 0), 1)
        XCTAssertEqual(InputLevelMeter.normalized(decibels: -.infinity), 0)
        XCTAssertEqual(InputLevelMeter.normalized(decibels: .nan), 0)
        // A full-scale sine has an RMS of 1/√2, about -3 dBFS.
        let sine = (0..<4_800).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        XCTAssertEqual(sine.withUnsafeBufferPointer { InputLevelMeter.decibels(samples: $0.baseAddress!, count: $0.count) }, -3.01, accuracy: 0.05)

        let meter = InputLevelMeter()
        meter.push(1)
        XCTAssertGreaterThan(meter.level, 0.6, "Rises fast")
        let peak = meter.level
        meter.push(0)
        XCTAssertLessThan(meter.level, peak)
        XCTAssertGreaterThan(meter.level, 0.3, "Falls slower than it rises")
        XCTAssertEqual(meter.history.count, InputLevelMeter.historyLength)
        XCTAssertEqual(meter.history.last, meter.level)
        meter.reset()
        XCTAssertEqual(meter.level, 0)
        XCTAssertEqual(meter.history, Array(repeating: 0, count: InputLevelMeter.historyLength), "No recording, no motion")
    }

    /// The voice-processed path reports the loudness of what it records,
    /// driven by a scripted engine instead of a microphone.
    func testVoiceProcessedCaptureReportsTheLevelItRecords() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let engine = LevelScriptedEngine(format: format)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("level-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = DispatchQueue(label: "RecordControlTests.capture")
        let capture = try VoiceProcessedCapture(url: url, queue: queue) { engine }
        try queue.sync { try capture.start() }
        XCTAssertEqual(capture.currentLevel(), 0, "Silent before any audio")

        try engine.deliver(amplitude: 0.1)
        // A 0.1 sine is about -23 dBFS: clearly speech-loud, not full scale.
        XCTAssertEqual(capture.currentLevel(), InputLevelMeter.normalized(decibels: -23.0), accuracy: 0.02)
        try engine.deliver(amplitude: 0)
        XCTAssertEqual(capture.currentLevel(), 0, "Silence reads as silence")
        _ = queue.sync { capture.finish() }
    }

    // MARK: Pixels

    /// Ink when ready and when listening, with only the small stop square in
    /// vermilion while recording, faded when nothing can be recorded, read
    /// straight from rendered pixels in both appearances.
    func testRecordControlColorsComeFromTheirTokens() throws {
        for scheme in [ColorScheme.light, .dark] {
            let background = ThemePalette.chromeBackground(scheme)
            func discColor(_ phase: RecordButtonPhase) throws -> NSColor {
                let bitmap = try ShareReadyRenders.render(
                    AnyView(RecordButtonFace(phase: phase).background(background)),
                    size: CGSize(width: WFRecordControl.size, height: WFRecordControl.size), scheme: scheme
                )
                // 13 pt left of center: on the disc, clear of the glyph and the edge light.
                return try XCTUnwrap(ShareReadyRenders.pixel(in: bitmap, at: CGPoint(x: 13, y: 26), viewSize: WFRecordControl.size))
            }
            // Each token drawn flat through the same renderer, so color
            // management treats the reference and the control alike.
            func swatch(_ color: Color) throws -> NSColor {
                let bitmap = try ShareReadyRenders.render(AnyView(color), size: CGSize(width: WFRecordControl.size, height: WFRecordControl.size), scheme: scheme)
                return try XCTUnwrap(ShareReadyRenders.pixel(in: bitmap, at: CGPoint(x: 13, y: 26), viewSize: WFRecordControl.size))
            }
            let ready = try discColor(.ready)
            let listening = try discColor(.listening)
            let unavailable = try discColor(.unavailable)
            assertClose(ready, try swatch(ThemePalette.ink(scheme)), "\(scheme) ready disc is ink")
            assertClose(listening, try swatch(ThemePalette.ink(scheme)), "\(scheme) listening keeps the calm ink disc")
            let stopBitmap = try ShareReadyRenders.render(
                AnyView(RecordButtonFace(phase: .listening).background(background)),
                size: CGSize(width: WFRecordControl.size, height: WFRecordControl.size), scheme: scheme
            )
            let stop = try XCTUnwrap(ShareReadyRenders.pixel(in: stopBitmap, at: CGPoint(x: 26, y: 26), viewSize: WFRecordControl.size))
            assertClose(stop, try swatch(ThemePalette.signal(scheme)), "\(scheme) only the small stop square is vermilion")
            let backdrop = try swatch(background)
            XCTAssertLessThan(distance(unavailable, backdrop), distance(ready, backdrop) * 0.5,
                              "\(scheme) unavailable fades toward the window so it never looks ready")
        }
    }

    /// A louder voice grows the halo; silence leaves it at the disc.
    func testHaloFollowsTheLevelAndHoldsStillWithReduceMotion() throws {
        XCTAssertEqual(RecordButtonFace.haloDiameter(level: 0, reduceMotion: false), WFRecordControl.disc + 12 * 0.18, accuracy: 0.01)
        XCTAssertEqual(RecordButtonFace.haloDiameter(level: 1, reduceMotion: false), WFRecordControl.size, accuracy: 0.01)
        XCTAssertEqual(RecordButtonFace.haloDiameter(level: 0, reduceMotion: true), RecordButtonFace.haloDiameter(level: 1, reduceMotion: true),
                       "Reduce Motion keeps the halo one size")
        XCTAssertLessThan(RecordButtonFace.haloOpacity(level: 0, reduceMotion: true), RecordButtonFace.haloOpacity(level: 1, reduceMotion: true),
                          "and lets the level show as strength instead")

        let background = ThemePalette.chromeBackground(.light)
        func ringPixel(level: CGFloat) throws -> NSColor {
            let bitmap = try ShareReadyRenders.render(
                AnyView(RecordButtonFace(phase: .listening, level: level).background(background)),
                size: CGSize(width: WFRecordControl.size, height: WFRecordControl.size), scheme: .light
            )
            // Between the disc (radius 20) and the ring (radius 24.5).
            return try XCTUnwrap(ShareReadyRenders.pixel(in: bitmap, at: CGPoint(x: 26 - 23, y: 26), viewSize: WFRecordControl.size))
        }
        let quiet = try ringPixel(level: 0)
        let loud = try ringPixel(level: 1)
        XCTAssertLessThan(distance(quiet, resolved(background, .light)), 0.04, "Silence leaves the space around the disc clear")
        XCTAssertGreaterThan(distance(loud, resolved(background, .light)), 0.08, "A loud voice tints it")
    }

    /// Working states trace a turning arc; with Reduce Motion two frames
    /// a quarter second apart are identical.
    func testWorkingArcTurnsOnlyWithoutReduceMotion() throws {
        func frames(reduceMotion: Bool) throws -> (Data, Data) {
            let view = AnyView(RecordButtonFace(phase: .working)
                .background(ThemePalette.chromeBackground(.light))
                .environment(\.reduceMotionOverride, reduceMotion))
            let size = CGSize(width: WFRecordControl.size, height: WFRecordControl.size)
            let first = try ShareReadyRenders.render(view, size: size, scheme: .light)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            let second = try ShareReadyRenders.render(view, size: size, scheme: .light)
            return (try XCTUnwrap(first.tiffRepresentation), try XCTUnwrap(second.tiffRepresentation))
        }
        let moving = try frames(reduceMotion: false)
        XCTAssertNotEqual(moving.0, moving.1, "The arc turns")
        let still = try frames(reduceMotion: true)
        XCTAssertEqual(still.0, still.1, "Reduce Motion stops it")
    }

    func testProcessingWaveMovesOnlyWithoutReduceMotion() throws {
        XCTAssertNotEqual(IndicatorProcessingWave.levels(bars: 5, at: 0), IndicatorProcessingWave.levels(bars: 5, at: 0.3))
        func frames(reduceMotion: Bool) throws -> (Data, Data) {
            let view = AnyView(IndicatorProcessingWave().padding(4).background(BrandPalette.charcoal)
                .environment(\.reduceMotionOverride, reduceMotion))
            let first = try ShareReadyRenders.render(view, size: CGSize(width: 40, height: 28), scheme: .dark)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            let second = try ShareReadyRenders.render(view, size: CGSize(width: 40, height: 28), scheme: .dark)
            return (try XCTUnwrap(first.tiffRepresentation), try XCTUnwrap(second.tiffRepresentation))
        }
        let moving = try frames(reduceMotion: false)
        XCTAssertNotEqual(moving.0, moving.1)
        let still = try frames(reduceMotion: true)
        XCTAssertEqual(still.0, still.1)
    }

    // MARK: Stable dimensions

    func testEveryPhaseKeepsOneFrame() {
        for phase in RecordButtonPhase.allCases {
            for level in [CGFloat(0), 1] {
                let host = NSHostingView(rootView: RecordButtonFace(phase: phase, level: level))
                XCTAssertEqual(host.fittingSize, CGSize(width: WFRecordControl.size, height: WFRecordControl.size), "\(phase) at \(level)")
            }
        }
    }

    func testDockKeepsOneHeightInEveryStatusAndWidth() {
        let statuses: [DictationDockStatus] = [
            .ready, .connecting, .recording(3_599), .meeting(4_000), .transcribing, .loadingModel, .processingQueue, .savingMeeting, .noMicrophone,
        ]
        for width in [CGFloat(440), 560, 900] {
            let heights = Set(statuses.map { status in
                NSHostingView(rootView: DictationDock(
                    status: status, shortcut: "⌃ / fn", writingSelection: .constant(.builtIn(.everyday)),
                    onLearn: {}, microphones: [MainWindowFixtures.microphone], currentMicrophoneID: MainWindowFixtures.microphone.id,
                    onSelectMicrophone: { _ in }, onRecord: {}
                ).frame(width: width)).fittingSize.height
            })
            XCTAssertEqual(heights.count, 1, "Dock heights at \(width): \(heights)")
        }
    }

    /// Every state fits the capsule's widest size, so no message is clipped,
    /// and listening stays a small pill: a dot, the waveform, and the clock.
    func testIndicatorWordsFitTheCapsule() throws {
        let viewModel = IndicatorViewModel(
            latestDictationGate: LatestDictationGate(),
            transcriptionService: TranscriptionService(engine: ControlledTranscriptionEngine { _ in })
        )
        defer { viewModel.cleanup() }
        viewModel.recordingStartedAt = Date().addingTimeInterval(-3_599)
        let states: [RecordingState] = [
            .connecting, .recording, .decoding, .busy, .noMicrophone, .recordingFailed, .recordingCutShort,
            .transcriptionFailed, .pasteFailed, .clipboardFailed,
        ]
        var widths: [RecordingState: CGFloat] = [:]
        for state in states {
            viewModel.state = state
            var measured: CGFloat = 0
            let host = NSHostingView(rootView: IndicatorWindow(viewModel: viewModel) { measured = $0 })
            host.frame = NSRect(origin: .zero, size: IndicatorWindow.windowSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertGreaterThan(measured, 0, "\(state) reports its width")
            XCTAssertLessThanOrEqual(measured, IndicatorWindow.cardSize.width, "\(state) fits the capsule")
            widths[state] = measured
        }
        let listening = try XCTUnwrap(widths[.recording])
        XCTAssertLessThanOrEqual(listening, 120, "Listening is a small pill, even with a long clock")
        XCTAssertLessThan(listening, try XCTUnwrap(widths[.clipboardFailed]), "Only states with words grow")
        let messageWidth = NSHostingView(rootView: Text("Not pasted, in History").font(IndicatorWindow.font).fixedSize()).fittingSize.width
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(widths[.clipboardFailed]), messageWidth + 2 * IndicatorWindow.horizontalPadding,
                                    "The longest message is drawn whole, never shrunk")
    }

    /// Listening is quiet: no word, no blinking, one small dot, a short
    /// waveform, and a capsule shorter than before.
    func testListeningCapsuleIsQuiet() {
        XCTAssertLessThanOrEqual(IndicatorWindow.cardSize.height, 32)
        XCTAssertLessThanOrEqual(RecordingIndicator.diameter, 6)
        XCTAssertLessThanOrEqual(IndicatorWaveform.maxHeight, 12)
        XCTAssertNil(IndicatorWindow.message(for: .recording), "Listening draws no words")
        XCTAssertEqual(IndicatorWindow.accessibilityLabel(for: .recording, isFinalizing: false, isConfirmingCancel: false), "Listening",
                       "but VoiceOver still names it")
        XCTAssertEqual(IndicatorWindow.accessibilityLabel(for: .recording, isFinalizing: false, isConfirmingCancel: true),
                       "Press Escape to cancel")
        XCTAssertEqual(IndicatorWindow.accessibilityLabel(for: .decoding, isFinalizing: true, isConfirmingCancel: false), "Refining")
        XCTAssertEqual(IndicatorWindow.accessibilityLabel(for: .transcriptionFailed, isFinalizing: false, isConfirmingCancel: false),
                       "Transcription failed", "Failures are still spoken")
    }

    // MARK: Contrast

    func testNewTokensMeetContrastTargets() {
        for scheme in [ColorScheme.light, .dark] {
            let signal = resolved(ThemePalette.signal(scheme), scheme)
            let signalText = resolved(ThemePalette.signalText(scheme), scheme)
            let caution = resolved(ThemePalette.caution(scheme), scheme)
            XCTAssertGreaterThanOrEqual(contrast(signal, resolved(ThemePalette.ink(scheme), scheme)), 3,
                                        "stop square on the listening disc \(scheme)")
            for (name, surface) in [("chrome", ThemePalette.chromeBackground(scheme)), ("content", ThemePalette.contentBackground(scheme)),
                                    ("card", ThemePalette.cardBackground(scheme)), ("window", ThemePalette.windowBackground(scheme))] {
                let surface = resolved(surface, scheme)
                XCTAssertGreaterThanOrEqual(contrast(signal, surface), 3, "listening control against \(name) \(scheme)")
                XCTAssertGreaterThanOrEqual(contrast(caution, surface), 4.5, "warning text on \(name) \(scheme)")
                XCTAssertGreaterThanOrEqual(contrast(signalText, surface), 4.5, "listening and failure words on \(name) \(scheme)")
            }
        }
        // The capsule is charcoal over whatever is behind it; the worst case
        // is a white document, which shows through the most.
        for backdrop in [NSColor.white, NSColor.black] {
            let capsule = blend(resolved(BrandPalette.charcoal, .dark), over: backdrop, alpha: IndicatorWindow.fillOpacity)
            let words = blend(resolved(BrandPalette.ivory, .dark), over: capsule, alpha: IndicatorWindow.textOpacity)
            XCTAssertGreaterThanOrEqual(contrast(words, capsule), 7, "capsule words")
            XCTAssertGreaterThanOrEqual(contrast(resolved(BrandPalette.amber, .dark), capsule), 4.5, "capsule warnings")
            let clock = blend(resolved(BrandPalette.ivory, .dark), over: capsule, alpha: IndicatorWindow.clockOpacity)
            XCTAssertGreaterThanOrEqual(contrast(clock, capsule), 4.5, "capsule clock")
            let dot = resolved(ThemePalette.signalText(.dark), .dark)
            XCTAssertGreaterThanOrEqual(contrast(dot, capsule), 3, "the listening dot stays visible")
        }
    }

    // MARK: Helpers

    private func assertClose(_ a: NSColor, _ b: NSColor, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(distance(a, b), 0.04, "\(message): \(a) vs \(b)", file: file, line: line)
    }
}

/// Delivers buffers the way AVAudioEngine's tap would, without a microphone.
private final class LevelScriptedEngine: VoiceCaptureEngine {
    let format: AVAudioFormat
    private var tap: ((AVAudioPCMBuffer) -> Void)?
    var isRunning = false
    var onConfigurationChange: (() -> Void)?

    init(format: AVAudioFormat) { self.format = format }
    func enableVoiceProcessing() throws {}
    var inputFormat: AVAudioFormat { format }
    func installTap(format: AVAudioFormat, block: @escaping (AVAudioPCMBuffer) -> Void) { tap = block }
    func removeTap() { tap = nil }
    func start() throws { isRunning = true }
    func stop() { isRunning = false }

    func deliver(amplitude: Float) throws {
        let frames = AVAudioFrameCount(4_800)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] = amplitude * Float(sin(2 * Double.pi * 220 * Double(frame) / format.sampleRate))
        }
        tap?(buffer)
    }
}

/// Stands in for a live microphone session, which only the recorder can own.
final class RenderRecordingViewModel: ContentViewModel {
    var scriptedRecording = false
    override var isRecording: Bool { scriptedRecording }
}

@MainActor
enum ShareReadyRenders {
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["WF_RENDER_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("WorkFlowShareReadyRenders", isDirectory: true)
    }

    static func render(_ view: AnyView, size: CGSize, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let content = view
            .frame(width: size.width, height: size.height)
            .tint(ThemePalette.controlTint)
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertFalse(window.isVisible, "Renders stay offscreen")
        window.contentView = nil
        return bitmap
    }

    /// The sRGB color at a point given in view coordinates, top-left origin.
    static func pixel(in bitmap: NSBitmapImageRep, at point: CGPoint, viewSize: CGFloat) -> NSColor? {
        let scale = CGFloat(bitmap.pixelsWide) / viewSize
        return bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
    }

    static func save(_ bitmap: NSBitmapImageRep, name: String, in test: XCTestCase) {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG encoding failed for \(name)")
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

@MainActor
private func resolved(_ color: Color, _ scheme: ColorScheme) -> NSColor {
    let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
    var result = NSColor.clear
    appearance.performAsCurrentDrawingAppearance {
        result = NSColor(color).usingColorSpace(.sRGB) ?? .clear
    }
    return result
}

private func blend(_ top: NSColor, over bottom: NSColor, alpha: CGFloat) -> NSColor {
    let t = top.usingColorSpace(.sRGB)!, b = bottom.usingColorSpace(.sRGB)!
    return NSColor(srgbRed: t.redComponent * alpha + b.redComponent * (1 - alpha),
                   green: t.greenComponent * alpha + b.greenComponent * (1 - alpha),
                   blue: t.blueComponent * alpha + b.blueComponent * (1 - alpha), alpha: 1)
}

private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
    let x = a.usingColorSpace(.sRGB)!, y = b.usingColorSpace(.sRGB)!
    return max(abs(x.redComponent - y.redComponent), abs(x.greenComponent - y.greenComponent), abs(x.blueComponent - y.blueComponent))
}

private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
    func luminance(_ color: NSColor) -> CGFloat {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(srgb.redComponent) + 0.7152 * linear(srgb.greenComponent) + 0.0722 * linear(srgb.blueComponent)
    }
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}
