import AVFoundation
import Combine
import CoreAudio
import XCTest
@testable import OpenSuperWhisper

// MARK: - Scripted hardware

/// A capture that writes a real recording file, in the recorder's own
/// settings, only when a test feeds it audio.
final class ScriptedCapture: RecordingCapture {
    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames = 0
    private var finishes = 0
    private let onEnded: () -> Void
    private let log: (String) -> Void

    init(url: URL, channels: Int, onEnded: @escaping () -> Void, log: @escaping (String) -> Void) throws {
        self.url = url
        self.onEnded = onEnded
        self.log = log
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        file = try AVAudioFile(forWriting: url, settings: settings)
    }

    /// How many times the recorder closed this capture.
    var finishCount: Int { lock.withLock { finishes } }

    /// Seconds of a quiet tone, as a microphone would deliver them. Audio
    /// fed after the capture closed goes nowhere.
    func feed(seconds: Double) {
        lock.withLock {
            guard let file else { return }
            let count = Int(seconds * 16_000)
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(file.processingFormat.channelCount) {
                let samples = buffer.floatChannelData![channel]
                for index in 0..<count {
                    samples[index] = 0.2 * sinf(2 * .pi * 220 * Float(frames + index) / 16_000)
                }
            }
            try? file.write(from: buffer)
            frames += count
        }
    }

    /// The device went away: the recorder is told, as AVAudioRecorder's
    /// delegate tells it.
    func endOnItsOwn() {
        onEnded()
    }

    func finish() -> TimeInterval {
        let seconds: TimeInterval = lock.withLock {
            finishes += 1
            file = nil
            return Double(frames) / 16_000
        }
        log("finish \(url.lastPathComponent)")
        return seconds
    }

    func currentLevel() -> CGFloat { 0.5 }
}

final class ScriptedPlayback: RecordingPlayback {
    private let lock = NSLock()
    private var stops = 0
    let url: URL
    private let onFinished: () -> Void

    init(url: URL, onFinished: @escaping () -> Void) {
        self.url = url
        self.onFinished = onFinished
    }

    var stopCount: Int { lock.withLock { stops } }

    func stop() {
        lock.withLock { stops += 1 }
    }

    /// The recording played to its end.
    func finishPlaying() {
        onFinished()
    }
}

/// A voice-processing engine that never touches audio hardware.
final class ScriptedVoiceEngine: VoiceCaptureEngine {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private var tap: ((AVAudioPCMBuffer) -> Void)?
    var enableError: Error?
    var startError: Error?
    var isRunning = false
    var onConfigurationChange: (() -> Void)?

    func enableVoiceProcessing() throws {
        if let enableError { throw enableError }
    }

    var inputFormat: AVAudioFormat { format }

    func installTap(format: AVAudioFormat, block: @escaping (AVAudioPCMBuffer) -> Void) {
        tap = block
    }

    func removeTap() {
        tap = nil
    }

    func start() throws {
        if let startError { throw startError }
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func deliver(seconds: Double) {
        let count = AVAudioFrameCount(seconds * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        buffer.frameLength = count
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(count) {
            samples[index] = 0.2 * sinf(2 * .pi * 220 * Float(index) / Float(format.sampleRate))
        }
        tap?(buffer)
    }

    /// The hardware changed under the engine, which stops it.
    func changeHardware() {
        isRunning = false
        onConfigurationChange?()
    }
}

/// The Mac's audio hardware, scripted: one microphone, a system default
/// input, and captures and playbacks that only tests drive.
final class ScriptedRecordingHardware: RecordingHardware {
    static let microphoneID: AudioDeviceID = 42
    static let originalDefaultInput: AudioDeviceID = 7

    private let lock = NSLock()
    private var log: [String] = []
    private var openedCaptures: [ScriptedCapture] = []
    private var startedPlaybacks: [ScriptedPlayback] = []
    private var pendingVoiceEngines: [ScriptedVoiceEngine] = []
    private var microphone: MicrophoneService.AudioDevice? =
        .init(id: "scripted-microphone", name: "Scripted Microphone", manufacturer: nil, isBuiltIn: true)
    private var needsConnection = false
    private var channels = 1
    private var defaultInput: AudioDeviceID? = ScriptedRecordingHardware.originalDefaultInput
    private var captureFailure: Error?
    private var openSeconds: TimeInterval = 0

    // MARK: What a test sets

    func removeMicrophone() { lock.withLock { microphone = nil } }
    func requireConnection(_ value: Bool = true) { lock.withLock { needsConnection = value } }
    func setChannels(_ value: Int) { lock.withLock { channels = value } }
    func failStandardCapture(with error: Error?) { lock.withLock { captureFailure = error } }
    /// How long the microphone takes to open.
    func setOpenDuration(_ seconds: TimeInterval) { lock.withLock { openSeconds = seconds } }
    func provide(_ engine: ScriptedVoiceEngine) { lock.withLock { pendingVoiceEngines.append(engine) } }
    /// Someone else changed the Mac's default input.
    func userChoseDefaultInput(_ deviceID: AudioDeviceID) { lock.withLock { defaultInput = deviceID } }

    // MARK: What a test reads

    var events: [String] { lock.withLock { log } }
    var captures: [ScriptedCapture] { lock.withLock { openedCaptures } }
    /// The capture writing to `url`, once its microphone has opened.
    func capture(writingTo url: URL) -> ScriptedCapture? { lock.withLock { openedCaptures.first { $0.url == url } } }
    var playbacks: [ScriptedPlayback] { lock.withLock { startedPlaybacks } }
    var currentDefaultInput: AudioDeviceID? { lock.withLock { defaultInput } }

    private func record(_ event: String) {
        lock.withLock { log.append(event) }
    }

    // MARK: RecordingHardware

    func activeMicrophone() -> MicrophoneService.AudioDevice? { lock.withLock { microphone } }
    func activeMicrophoneRequiresConnection() -> Bool { lock.withLock { needsConnection } }
    func inputChannelCount(for device: MicrophoneService.AudioDevice) -> Int { lock.withLock { channels } }
    func deviceID(for device: MicrophoneService.AudioDevice) -> AudioDeviceID? { Self.microphoneID }
    func defaultInputDevice() -> AudioDeviceID? { lock.withLock { defaultInput } }

    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        lock.withLock {
            defaultInput = deviceID
            log.append("setDefaultInput \(deviceID)")
        }
        return true
    }

    func playStartSound() {
        record("playStartSound")
    }

    func startStandardCapture(at url: URL, channels: Int, onEnded: @escaping () -> Void) throws -> RecordingCapture {
        let (failure, seconds) = lock.withLock { (captureFailure, openSeconds) }
        if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
        if let failure {
            record("standardCaptureFailed")
            throw failure
        }
        let capture = try ScriptedCapture(url: url, channels: channels, onEnded: onEnded) { [weak self] in self?.record($0) }
        lock.withLock {
            openedCaptures.append(capture)
            log.append("startStandardCapture \(channels)ch \(url.lastPathComponent)")
        }
        return capture
    }

    func makeVoiceEngine() -> VoiceCaptureEngine {
        record("makeVoiceEngine")
        return lock.withLock { pendingVoiceEngines.isEmpty ? ScriptedVoiceEngine() : pendingVoiceEngines.removeFirst() }
    }

    func startPlayback(of url: URL, onFinished: @escaping () -> Void) throws -> RecordingPlayback {
        let playback = ScriptedPlayback(url: url, onFinished: onFinished)
        lock.withLock {
            startedPlaybacks.append(playback)
            log.append("startPlayback \(url.lastPathComponent)")
        }
        return playback
    }
}

/// A small deterministic generator, so a failing sequence can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - The recorder

/// The real `AudioRecorder` on scripted hardware: what it asks of the
/// hardware, what it publishes, and what it leaves on disk, across starts,
/// stops, cancels, a capture that dies on its own, and overlapping sessions.
/// Nothing opens a microphone or plays a sound, so this proves the recorder's
/// own lifecycle, not how AVAudioRecorder or a real device behaves.
@MainActor
final class RecorderLifecycleTests: XCTestCase {
    private var directory: URL!
    private var hardware: ScriptedRecordingHardware!
    private var recorder: AudioRecorder!
    private var cancellables = Set<AnyCancellable>()
    private var stoppedCaptures: [UUID] = []
    private var savedPreferences: [String: Any?] = [:]

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-recorder-\(UUID())")
        for key in ["reduceBackgroundAudio", "playSoundOnRecordStart"] {
            savedPreferences[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        hardware = ScriptedRecordingHardware()
        makeRecorder()
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        recorder = nil
        BackgroundAudioReductionMonitor.shared.status = .notUsed
        for (key, value) in savedPreferences {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRecorder(stopTail: TimeInterval = 0.05) {
        cancellables.removeAll()
        stoppedCaptures = []
        recorder = AudioRecorder(hardware: hardware, temporaryDirectory: directory, stopTail: stopTail)
        recorder.captureStopped
            .sink { [weak self] id in self?.stoppedCaptures.append(id) }
            .store(in: &cancellables)
    }

    // MARK: Helpers

    private func wait(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(what)", file: file, line: line)
    }

    /// Lets the recorder's queue and the main queue run what is pending.
    private func settle() async {
        for _ in 0..<12 { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Starts a recording and waits until its microphone is open.
    private func startLive(purpose: RecordingPurpose = .dictation) async -> (id: UUID, capture: ScriptedCapture) {
        let id = UUID()
        let before = hardware.captures.count
        XCTAssertTrue(recorder.startRecording(sessionID: id, purpose: purpose))
        await wait("the microphone to open") { hardware.captures.count == before + 1 }
        await wait("the recorder to publish recording") { recorder.isRecording }
        return (id, hardware.captures[before])
    }

    private func recordingFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func seconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    // MARK: Start and stop

    func testARecordingStartsOnTheChosenMicrophoneAndStopsWithItsAudio() async throws {
        let id = UUID()
        var completions: [String?] = []
        var startedURLs: [URL] = []
        XCTAssertTrue(recorder.startRecording(
            sessionID: id,
            completion: { completions.append($0) },
            started: { startedURLs.append($0) }
        ))
        XCTAssertTrue(recorder.ownsRecordingSession(id), "Owned before the microphone opens")
        await wait("the recorder to publish recording") { recorder.isRecording }

        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(completions.first ?? "missing")
        XCTAssertEqual(startedURLs.count, 1)
        let capture = try XCTUnwrap(hardware.captures.first)
        XCTAssertEqual(startedURLs.first, capture.url)
        XCTAssertEqual(hardware.currentDefaultInput, ScriptedRecordingHardware.microphoneID,
                       "The chosen microphone is the Mac's input while it records")
        XCTAssertFalse(hardware.events.contains("playStartSound"), "The start sound is off by default")
        XCTAssertFalse(recorder.isConnecting)

        capture.feed(seconds: 1)
        let stopped = await recorder.stopRecording(sessionID: id)
        let url = try XCTUnwrap(stopped)
        XCTAssertEqual(url, capture.url)
        XCTAssertEqual(try seconds(of: url), 1, accuracy: 0.01)
        XCTAssertEqual(capture.finishCount, 1)
        XCTAssertFalse(recorder.ownsRecordingSession(id))
        await wait("the recorder to publish idle") { !recorder.isRecording }
        XCTAssertEqual(hardware.currentDefaultInput, ScriptedRecordingHardware.originalDefaultInput,
                       "The Mac's input goes back when the recording ends")
        XCTAssertEqual(hardware.events.filter { $0.hasPrefix("setDefaultInput") },
                       ["setDefaultInput 42", "setDefaultInput 7"])
        XCTAssertTrue(stoppedCaptures.isEmpty, "A recording its owner stopped is not one that stopped on its own")
    }

    func testEveryInputChannelOfTheMicrophoneIsRecorded() async throws {
        hardware.setChannels(3)
        let (id, capture) = await startLive()
        capture.feed(seconds: 1)
        let stopped = await recorder.stopRecording(sessionID: id)
        let url = try XCTUnwrap(stopped)
        XCTAssertEqual(try AVAudioFile(forReading: url).fileFormat.channelCount, 3)
        XCTAssertTrue(hardware.events.contains { $0.hasPrefix("startStandardCapture 3ch") })
    }

    func testARecordingTooShortToUseIsDiscarded() async {
        let (id, capture) = await startLive()
        capture.feed(seconds: 0.1)
        let stopped = await recorder.stopRecording(sessionID: id)
        XCTAssertNil(stopped)
        XCTAssertEqual(recordingFiles(), [], "Nothing is left for launch recovery to bring back")
        XCTAssertEqual(capture.finishCount, 1)
    }

    func testTheStartSoundPlaysOnlyWhenItIsSwitchedOn() async {
        UserDefaults.standard.set(true, forKey: "playSoundOnRecordStart")
        let (id, _) = await startLive()
        XCTAssertEqual(hardware.events.filter { $0 == "playStartSound" }.count, 1)
        recorder.cancelRecording(sessionID: id)
        await settle()
    }

    func testAMicrophoneThatNeedsConnectingShowsConnectingUntilAudioArrives() async {
        hardware.requireConnection()
        let id = UUID()
        XCTAssertTrue(recorder.startRecording(sessionID: id))
        await wait("the recorder to publish connecting") { recorder.isConnecting }
        XCTAssertFalse(recorder.isRecording, "Not recording until the microphone delivers audio")
        await wait("the microphone to open") { hardware.captures.count == 1 }
        let capture = hardware.captures[0]

        await settle()
        XCTAssertTrue(recorder.isConnecting, "Still connecting while no audio arrives")
        XCTAssertFalse(recorder.isRecording)

        capture.feed(seconds: 0.5)
        await wait("the recorder to publish recording") { recorder.isRecording }
        XCTAssertFalse(recorder.isConnecting)
        recorder.cancelRecording(sessionID: id)
        await settle()
    }

    // MARK: Start failures

    func testAMicrophoneThatDeclinesReportsWhyAndLeavesNothingBehind() async {
        hardware.failStandardCapture(with: StandardCaptureError.declined)
        let id = UUID()
        var completions: [String?] = []
        XCTAssertTrue(recorder.startRecording(sessionID: id, completion: { completions.append($0) }))
        await wait("the start to report") { !completions.isEmpty }

        XCTAssertEqual(completions, ["The microphone declined the recording request."])
        XCTAssertFalse(recorder.ownsRecordingSession(id))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recordingFiles(), [])
        XCTAssertEqual(hardware.currentDefaultInput, ScriptedRecordingHardware.originalDefaultInput)
        let stopped = await recorder.stopRecording(sessionID: id)
        XCTAssertNil(stopped, "A stop of a start that failed has no audio")

        hardware.failStandardCapture(with: nil)
        let (next, _) = await startLive()
        recorder.cancelRecording(sessionID: next)
        await settle()
    }

    func testNoMicrophoneReportsItAndOpensNothing() async {
        hardware.removeMicrophone()
        var completions: [String?] = []
        let id = UUID()
        XCTAssertTrue(recorder.startRecording(sessionID: id, completion: { completions.append($0) }))
        await wait("the start to report") { !completions.isEmpty }
        XCTAssertEqual(completions, ["The selected microphone is no longer available."])
        XCTAssertFalse(recorder.ownsRecordingSession(id))
        XCTAssertTrue(hardware.captures.isEmpty)
        XCTAssertFalse(recorder.hasActiveMicrophone)
    }

    // MARK: Cancel

    func testCancelDiscardsTheAudioAndRestoresTheInput() async {
        let (id, capture) = await startLive()
        capture.feed(seconds: 2)
        recorder.cancelRecording(sessionID: id)
        XCTAssertFalse(recorder.ownsRecordingSession(id), "Ownership ends before cancel returns")
        await wait("the capture to close") { capture.finishCount == 1 }
        await wait("the recorder to publish idle") { !recorder.isRecording }
        XCTAssertEqual(recordingFiles(), [])
        XCTAssertEqual(hardware.currentDefaultInput, ScriptedRecordingHardware.originalDefaultInput)
        let stopped = await recorder.stopRecording(sessionID: id)
        XCTAssertNil(stopped)
        XCTAssertEqual(capture.finishCount, 1, "A late stop closes nothing twice")
    }

    /// Esc, or a modifier used as part of another shortcut, cancels right
    /// after the press. The main thread must not wait for the microphone,
    /// which can take a Bluetooth device seconds to open.
    func testCancelNeverWaitsForAMicrophoneThatIsStillOpening() async {
        hardware.setOpenDuration(0.6)
        let id = UUID()
        XCTAssertTrue(recorder.startRecording(sessionID: id))
        try? await Task.sleep(nanoseconds: 50_000_000)

        let began = Date()
        recorder.cancelRecording(sessionID: id)
        let waited = Date().timeIntervalSince(began)
        XCTAssertLessThan(waited, 0.2, "Cancel returned after \(waited) s while the microphone was still opening")
        XCTAssertFalse(recorder.ownsRecordingSession(id))

        // A new press is accepted at once and records after the cancelled one closed.
        hardware.setOpenDuration(0)
        let next = UUID()
        XCTAssertTrue(recorder.startRecording(sessionID: next))
        await wait("the cancelled capture to close and the next to open", timeout: 5) {
            hardware.captures.count == 2 && hardware.captures[0].finishCount == 1
        }
        await wait("the recorder to publish recording") { recorder.isRecording }
        XCTAssertEqual(recordingFiles(), [hardware.captures[1].url.lastPathComponent], "Only the new recording is on disk")
        recorder.cancelRecording(sessionID: next)
        await settle()
    }

    func testAPressCancelledBeforeItsMicrophoneWasAskedForOpensNothing() async {
        // The first press is still opening its microphone, which holds the
        // recorder's queue, when it is cancelled and the next press arrives.
        hardware.setOpenDuration(0.3)
        let first = UUID()
        XCTAssertTrue(recorder.startRecording(sessionID: first))
        try? await Task.sleep(nanoseconds: 60_000_000)
        recorder.cancelRecording(sessionID: first)
        hardware.setOpenDuration(0)

        // The second press is cancelled before the queue reaches it.
        let second = UUID()
        XCTAssertTrue(recorder.startRecording(sessionID: second))
        recorder.cancelRecording(sessionID: second)

        await wait("the first capture to close", timeout: 5) { hardware.captures.first?.finishCount == 1 }
        await settle()
        XCTAssertEqual(hardware.captures.count, 1, "The second press was cancelled before its microphone opened")
        XCTAssertEqual(recordingFiles(), [])
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(hardware.currentDefaultInput, ScriptedRecordingHardware.originalDefaultInput)
    }

    // MARK: A capture that stops on its own

    /// The microphone is unplugged, or AVAudioRecorder fails, in the middle
    /// of a recording made with the standard capture.
    func testAStandardCaptureThatStopsOnItsOwnKeepsItsAudioAndTellsItsOwnerOnce() async throws {
        let (id, capture) = await startLive()
        capture.feed(seconds: 1.5)

        capture.endOnItsOwn()
        capture.endOnItsOwn()
        await wait("the owner to be told") { !stoppedCaptures.isEmpty }
        await settle()

        XCTAssertEqual(stoppedCaptures, [id], "Told once")
        XCTAssertFalse(recorder.isRecording, "Never shows recording while nothing is captured")
        XCTAssertTrue(recorder.ownsRecordingSession(id), "The session stays with its owner until the owner ends it")
        XCTAssertEqual(recordingFiles(), [capture.url.lastPathComponent], "The audio recorded until then is kept")
        XCTAssertFalse(recorder.startRecording(sessionID: UUID()), "Nobody else takes the recorder before the owner ends it")

        let stopped = await recorder.stopRecording(sessionID: id)
        let url = try XCTUnwrap(stopped, "The owner's usual stop returns the audio")
        XCTAssertEqual(try seconds(of: url), 1.5, accuracy: 0.01)
        XCTAssertEqual(capture.finishCount, 1)
        XCTAssertEqual(hardware.currentDefaultInput, ScriptedRecordingHardware.originalDefaultInput)
        XCTAssertEqual(stoppedCaptures, [id])
    }

    func testACaptureThatStoppedOnItsOwnCanStillBeCancelled() async {
        let (id, capture) = await startLive()
        capture.feed(seconds: 1)
        capture.endOnItsOwn()
        await wait("the owner to be told") { !stoppedCaptures.isEmpty }
        recorder.cancelRecording(sessionID: id)
        await wait("the capture to close") { capture.finishCount == 1 }
        await settle()
        XCTAssertEqual(recordingFiles(), [], "Cancel is still the one thing that discards audio")
    }

    func testACaptureThatEndsAfterItsOwnerStoppedItTellsNobody() async {
        let (id, capture) = await startLive()
        capture.feed(seconds: 1)
        let stopped = await recorder.stopRecording(sessionID: id)
        XCTAssertNotNil(stopped)
        capture.endOnItsOwn()
        await settle()
        XCTAssertTrue(stoppedCaptures.isEmpty)
    }

    // MARK: Voice processing through the recorder

    func testVoiceProcessingThatCannotRestartEndsTheSessionWithItsAudio() async throws {
        UserDefaults.standard.set(true, forKey: "reduceBackgroundAudio")
        let engine = ScriptedVoiceEngine()
        let replacement = ScriptedVoiceEngine()
        replacement.startError = NSError(domain: "scripted", code: -10876)
        hardware.provide(engine)
        hardware.provide(replacement)
        let id = UUID()
        XCTAssertTrue(recorder.startRecording(sessionID: id))
        await wait("the recorder to publish recording") { recorder.isRecording }
        XCTAssertTrue(hardware.captures.isEmpty, "Voice processing records without the standard capture")

        engine.deliver(seconds: 1)
        engine.changeHardware()
        await wait("the owner to be told") { !stoppedCaptures.isEmpty }
        XCTAssertEqual(stoppedCaptures, [id])
        XCTAssertFalse(recorder.isRecording)

        let stopped = await recorder.stopRecording(sessionID: id)
        let url = try XCTUnwrap(stopped)
        XCTAssertEqual(try seconds(of: url), 1, accuracy: 0.05)
        await settle()
        XCTAssertEqual(BackgroundAudioReductionMonitor.shared.status,
                       .stopped("The audio device changed during the last recording and voice processing couldn’t restart."))
    }

    func testVoiceProcessingThatCannotStartRecordsTheMicrophoneAsItIs() async throws {
        UserDefaults.standard.set(true, forKey: "reduceBackgroundAudio")
        let engine = ScriptedVoiceEngine()
        engine.enableError = NSError(domain: "scripted", code: -10876)
        hardware.provide(engine)
        let (id, capture) = await startLive()
        capture.feed(seconds: 1)
        let stopped = await recorder.stopRecording(sessionID: id)
        XCTAssertNotNil(stopped)
        await settle()
        guard case .unavailable = BackgroundAudioReductionMonitor.shared.status else {
            return XCTFail("Settings says the last recording used the microphone as is")
        }
    }

    func testAMeetingNeverUsesVoiceProcessing() async {
        UserDefaults.standard.set(true, forKey: "reduceBackgroundAudio")
        let (id, _) = await startLive(purpose: .meeting)
        XCTAssertFalse(hardware.events.contains("makeVoiceEngine"))
        recorder.cancelRecording(sessionID: id)
        await settle()
    }

    // MARK: Ownership and overlap

    func testOnlyTheOwnerCanStopOrCancel() async throws {
        let (id, capture) = await startLive()
        capture.feed(seconds: 1)
        let stranger = UUID()
        XCTAssertFalse(recorder.startRecording(sessionID: stranger), "One recording at a time")
        recorder.cancelRecording(sessionID: stranger)
        let strangerStop = await recorder.stopRecording(sessionID: stranger)
        XCTAssertNil(strangerStop)
        await settle()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(capture.finishCount, 0)

        let stopped = await recorder.stopRecording(sessionID: id)
        XCTAssertNotNil(stopped)
        let again = await recorder.stopRecording(sessionID: id)
        XCTAssertNil(again, "A second stop has nothing to return")
        XCTAssertEqual(capture.finishCount, 1)
    }

    /// A press right after a release starts the next recording while the
    /// last one still captures its final word. The Mac's input must not go
    /// back to the earlier device under either of them.
    func testTheSystemInputGoesBackOnlyWhenNoRecordingIsStillCapturing() async throws {
        makeRecorder(stopTail: 0.3)
        let (first, firstCapture) = await startLive()
        firstCapture.feed(seconds: 1)
        async let firstStop = recorder.stopRecording(sessionID: first)
        try await Task.sleep(nanoseconds: 60_000_000)

        // The next press, inside the first recording's stop tail.
        let second = UUID()
        XCTAssertTrue(recorder.startRecording(sessionID: second))
        await wait("the second microphone to open") { hardware.captures.count == 2 }
        let secondCapture = hardware.captures[1]
        secondCapture.feed(seconds: 1)
        async let secondStop = recorder.stopRecording(sessionID: second)

        let urls = await [firstStop, secondStop]
        XCTAssertNotNil(urls[0])
        XCTAssertNotNil(urls[1])
        await settle()

        let events = hardware.events.filter { $0.hasPrefix("setDefaultInput") || $0.hasPrefix("finish") }
        XCTAssertEqual(events, [
            "setDefaultInput 42",
            "finish \(firstCapture.url.lastPathComponent)",
            "finish \(secondCapture.url.lastPathComponent)",
            "setDefaultInput 7",
        ], "Switched once, and restored once after both recordings closed")
        XCTAssertEqual(hardware.currentDefaultInput, ScriptedRecordingHardware.originalDefaultInput)
    }

    func testAnInputTheUserChoseWhileRecordingIsKept() async {
        let (id, capture) = await startLive()
        capture.feed(seconds: 1)
        hardware.userChoseDefaultInput(99)
        _ = await recorder.stopRecording(sessionID: id)
        await settle()
        XCTAssertEqual(hardware.currentDefaultInput, 99, "Their change during the recording is not undone")
    }

    // MARK: Playback

    /// A History recording still playing through the speakers would be
    /// recorded by the microphone and transcribed as if it were spoken.
    func testAHistoryRecordingStopsPlayingWhenARecordingStarts() async {
        let played = directory.appendingPathComponent("history.wav")
        recorder.playRecording(url: played)
        XCTAssertTrue(recorder.isPlaying)
        XCTAssertEqual(recorder.currentlyPlayingURL, played)
        let playback = hardware.playbacks[0]

        let (id, _) = await startLive()
        XCTAssertEqual(playback.stopCount, 1)
        XCTAssertFalse(recorder.isPlaying)
        XCTAssertNil(recorder.currentlyPlayingURL)
        recorder.cancelRecording(sessionID: id)
        await settle()
    }

    func testARefusedStartLeavesPlaybackAlone() async {
        let (id, _) = await startLive()
        let played = directory.appendingPathComponent("history.wav")
        recorder.playRecording(url: played)
        XCTAssertFalse(recorder.startRecording(sessionID: UUID()), "The recorder is busy")
        XCTAssertTrue(recorder.isPlaying)
        XCTAssertEqual(hardware.playbacks[0].stopCount, 0)
        recorder.cancelRecording(sessionID: id)
        await settle()
    }

    func testPlaybackClearsWhenItFinishesAndWhenAnotherReplacesIt() {
        let first = directory.appendingPathComponent("first.wav")
        let second = directory.appendingPathComponent("second.wav")
        recorder.playRecording(url: first)
        recorder.playRecording(url: second)
        XCTAssertEqual(hardware.playbacks[0].stopCount, 1, "Starting another stops the one playing")
        XCTAssertEqual(recorder.currentlyPlayingURL, second)

        hardware.playbacks[0].finishPlaying()
        XCTAssertTrue(recorder.isPlaying, "A late end of the replaced playback clears nothing")
        hardware.playbacks[1].finishPlaying()
        XCTAssertFalse(recorder.isPlaying)
        XCTAssertNil(recorder.currentlyPlayingURL)
    }

    // MARK: Pressure

    /// Random presses, releases, cancels, device losses and stale signals,
    /// some of them overlapping. Afterwards every microphone that was opened
    /// has been closed exactly once, every stop has answered, a file is on
    /// disk exactly when a stop returned it, and the Mac's input is back.
    func testRandomSequencesLeaveTheRecorderConsistent() async throws {
        makeRecorder(stopTail: 0.02)
        var generator = SeededGenerator(state: 0x5EED_CAFE)
        var kept: Set<String> = []
        var stops: [Task<URL?, Never>] = []
        var endedSessions: Set<UUID> = []

        for round in 0..<60 {
            let id = UUID()
            var recordingURL: URL?
            let accepted = recorder.startRecording(sessionID: id, started: { recordingURL = $0 })
            XCTAssertTrue(accepted, "Round \(round): the recorder was free")
            // Half the time the release comes before the microphone is open.
            if Bool.random(using: &generator) {
                await wait("round \(round) to open") { recordingURL != nil }
            }
            let capture = recordingURL.flatMap { hardware.capture(writingTo: $0) }
            capture?.feed(seconds: Double.random(in: 0...1, using: &generator))

            if Int.random(in: 0..<4, using: &generator) == 0, let capture {
                capture.endOnItsOwn()
                endedSessions.insert(id)
                if Bool.random(using: &generator) { await settle() }
            }
            // Signals from a session that never owned the recorder.
            if Bool.random(using: &generator) { recorder.cancelRecording(sessionID: UUID()) }

            if Int.random(in: 0..<3, using: &generator) == 0 {
                recorder.cancelRecording(sessionID: id)
            } else {
                let recorder = recorder!
                stops.append(Task { await recorder.stopRecording(sessionID: id) })
                // Half the time the next press comes inside this stop tail.
                if Bool.random(using: &generator) { try await Task.sleep(nanoseconds: 30_000_000) }
            }
            // The recorder is free for the next press once this one let go.
            await wait("round \(round) to release the recorder") { !recorder.ownsRecordingSession(id) }
        }

        for stop in stops {
            if let url = await stop.value { kept.insert(url.lastPathComponent) }
        }
        await wait("every capture to close") { hardware.captures.allSatisfy { $0.finishCount == 1 } }
        await settle()

        XCTAssertEqual(Set(recordingFiles()), kept, "A file is on disk exactly when a stop returned it")
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isConnecting)
        XCTAssertEqual(hardware.currentDefaultInput, ScriptedRecordingHardware.originalDefaultInput)
        XCTAssertEqual(Set(stoppedCaptures).count, stoppedCaptures.count, "Nobody is told twice")
        XCTAssertTrue(Set(stoppedCaptures).isSubset(of: endedSessions), "Only a session whose capture stopped on its own is told")

        let (last, lastCapture) = await startLive()
        lastCapture.feed(seconds: 1)
        let stopped = await recorder.stopRecording(sessionID: last)
        XCTAssertNotNil(stopped, "The recorder still records afterwards")
    }

    // MARK: Audio a failed recorder left behind

    func testAudioLeftByARecorderThatStoppedOnItsOwnIsMeasuredAndItsHeaderFinished() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A finished file reads as it is.
        let finished = directory.appendingPathComponent("finished.wav")
        let finishedCapture = try ScriptedCapture(url: finished, channels: 1, onEnded: {}, log: { _ in })
        finishedCapture.feed(seconds: 2)
        _ = finishedCapture.finish()
        let untouched = try Data(contentsOf: finished)
        XCTAssertEqual(StandardCapture.salvagedDuration(of: finished), 2, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: finished), untouched, "A file that reads correctly is never written to")

        // A file whose sizes were never filled in holds its audio behind a
        // header that declares none.
        let unfinished = directory.appendingPathComponent("unfinished.wav")
        var bytes = [UInt8](untouched)
        let dataOffset = try XCTUnwrap(dataOffset(in: bytes))
        for index in 0..<4 {
            bytes[4 + index] = UInt8(truncatingIfNeeded: UInt32(dataOffset - 8) >> (8 * index))
            bytes[dataOffset - 4 + index] = 0
        }
        try Data(bytes).write(to: unfinished)
        XCTAssertEqual(try AVAudioFile(forReading: unfinished).length, 0, "It reads as empty before")
        XCTAssertEqual(StandardCapture.salvagedDuration(of: unfinished), 2, accuracy: 0.01)
        XCTAssertEqual(try seconds(of: unfinished), 2, accuracy: 0.01, "The engine can read it afterwards")

        let garbage = directory.appendingPathComponent("garbage.wav")
        try Data("not audio".utf8).write(to: garbage)
        XCTAssertEqual(StandardCapture.salvagedDuration(of: garbage), 0)
        XCTAssertEqual(StandardCapture.salvagedDuration(of: directory.appendingPathComponent("missing.wav")), 0)
    }

    private func dataOffset(in bytes: [UInt8]) -> Int? {
        var offset = 12
        while offset + 8 <= bytes.count {
            if bytes[offset..<offset + 4].elementsEqual(Array("data".utf8)) { return offset + 8 }
            let size = (0..<4).reduce(0) { $0 | Int(bytes[offset + 4 + $1]) << (8 * $1) }
            offset += 8 + size + size % 2
        }
        return nil
    }
}

// MARK: - Meetings

/// `MeetingSessionController` on the real recorder with scripted hardware.
@MainActor
final class MeetingLifecycleTests: XCTestCase {
    private var directory: URL!
    private var hardware: ScriptedRecordingHardware!
    private var recorder: AudioRecorder!
    private var meeting: MeetingSessionController!
    private var queued: [(url: URL, title: String, cleanup: Bool)] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-meeting-\(UUID())")
        hardware = ScriptedRecordingHardware()
        recorder = AudioRecorder(hardware: hardware, temporaryDirectory: directory, stopTail: 0.05)
        queued = []
        meeting = MeetingSessionController(recorder: recorder) { [weak self] url, title, cleanup in
            self?.queued.append((url, title, cleanup))
        }
    }

    override func tearDown() async throws {
        meeting = nil
        recorder = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func wait(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(what)", file: file, line: line)
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    func testAMeetingRecordsStopsAndIsQueuedOnce() async throws {
        XCTAssertTrue(meeting.start(title: "  Planning sync  ", cleanupRequested: true))
        XCTAssertEqual(meeting.state, .recording(title: "Planning sync"))
        XCTAssertNil(meeting.startedAt, "The clock waits for the microphone")
        await wait("the meeting's clock to start") { meeting.startedAt != nil }
        XCTAssertFalse(meeting.isConnecting)
        hardware.captures[0].feed(seconds: 2)

        await meeting.stop()
        XCTAssertEqual(meeting.state, .idle)
        XCTAssertNil(meeting.issue)
        XCTAssertNil(meeting.startedAt)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.title, "Planning sync")
        XCTAssertEqual(queued.first?.cleanup, true)
        XCTAssertEqual(files(), [try XCTUnwrap(queued.first).url.lastPathComponent])
        await meeting.stop()
        XCTAssertEqual(queued.count, 1, "A second stop queues nothing")
    }

    /// The microphone is unplugged in the middle of a meeting.
    func testAMeetingWhoseMicrophoneStopsIsSavedWithItsAudioAndSaysSo() async throws {
        XCTAssertTrue(meeting.start(title: "Weekly sync"))
        await wait("the meeting's clock to start") { meeting.startedAt != nil }
        let capture = hardware.captures[0]
        capture.feed(seconds: 3)

        capture.endOnItsOwn()
        await wait("the meeting to be saved") { meeting.state == .idle && !queued.isEmpty }

        XCTAssertEqual(queued.count, 1, "Saved once")
        let saved = try XCTUnwrap(queued.first)
        XCTAssertEqual(saved.title, "Weekly sync")
        let file = try AVAudioFile(forReading: saved.url)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 3, accuracy: 0.01, "With the audio recorded until then")
        XCTAssertEqual(meeting.issue, .stoppedEarly)
        XCTAssertEqual(meeting.statusLabel, "Meeting stopped early — open WorkFlow for details")
        XCTAssertFalse(meeting.isRecording, "Never keeps showing a meeting that records nothing")
        XCTAssertNil(meeting.startedAt)
        XCTAssertFalse(recorder.isRecording)

        meeting.clearError()
        XCTAssertNil(meeting.issue)
        XCTAssertTrue(meeting.start(title: "Next"), "The recorder is free for the next meeting")
        meeting.cancel()
    }

    func testAMeetingWhoseMicrophoneStopsBeforeAnyAudioFailsAndKeepsNothing() async {
        XCTAssertTrue(meeting.start(title: "Short"))
        await wait("the meeting's clock to start") { meeting.startedAt != nil }
        hardware.captures[0].endOnItsOwn()
        await wait("the meeting to end") { meeting.state == .idle && meeting.issue != nil }
        XCTAssertEqual(meeting.issue, .failed("The microphone stopped before any usable audio was captured."))
        XCTAssertTrue(queued.isEmpty)
        XCTAssertEqual(files(), [])
    }

    func testAMeetingOnAConnectingMicrophoneShowsConnectingAndStartsItsClockWithTheAudio() async {
        hardware.requireConnection()
        XCTAssertTrue(meeting.start(title: "Headset"))
        await wait("the meeting to show connecting") { meeting.isConnecting }
        XCTAssertNil(meeting.startedAt, "No clock while nothing is recorded")
        XCTAssertTrue(meeting.isRecording, "The meeting is still the one to stop")

        await wait("the microphone to open") { hardware.captures.count == 1 }
        hardware.captures[0].feed(seconds: 0.5)
        await wait("the meeting's clock to start") { meeting.startedAt != nil }
        XCTAssertFalse(meeting.isConnecting)
        meeting.cancel()
        XCTAssertFalse(meeting.isConnecting)
    }

    // MARK: The dock's record control

    /// The window's own dock, wired to the meeting as the window wires it.
    private func dock(_ status: DictationDockStatus) -> OffscreenHost<DictationDock> {
        OffscreenHost(
            DictationDock(status: status, shortcut: "fn", writingSelection: .constant(.builtIn(.everyday)),
                          onRecord: { [meeting] in Task { await meeting?.stop() } }),
            size: CGSize(width: 560, height: DictationDock.expectedHeight)
        )
    }

    /// A Bluetooth microphone that never delivers audio: the dock's record
    /// control still ends the meeting, and nothing is left behind.
    func testTheDockStopsAMeetingWhoseMicrophoneNeverConnects() async throws {
        hardware.requireConnection()
        XCTAssertTrue(meeting.start(title: "Headset"))
        await wait("the meeting to show connecting") { meeting.isConnecting }
        await wait("the microphone to open") { hardware.captures.count == 1 }

        let status = DictationDockStatus.startedMeeting(isConnecting: meeting.isConnecting)
        XCTAssertEqual(status.title, "Connecting microphone…", "The dock does not claim to record")
        let host = dock(status)
        XCTAssertEqual(host.buttons.count, 1, "The record control is the dock's one button here")
        let record = try XCTUnwrap(host.buttons.first)
        XCTAssertTrue(record.isEnabled)
        record.performClick(nil)

        await wait("the meeting to end") { meeting.state == .idle && meeting.issue != nil }
        XCTAssertTrue(meeting.issue?.message.hasPrefix("No usable audio was captured") == true)
        XCTAssertFalse(meeting.isConnecting)
        XCTAssertTrue(queued.isEmpty, "Nothing was recorded, so nothing is queued")
        XCTAssertEqual(files(), [], "The empty recording is removed")
        XCTAssertEqual(hardware.captures[0].finishCount, 1, "The microphone is released")

        hardware.requireConnection(false)
        XCTAssertTrue(meeting.start(title: "Next"), "The recorder is free for the next meeting")
        meeting.cancel()
    }

    /// A slow microphone: the meeting waits, records once audio arrives, and
    /// the same control then stops and saves it.
    func testTheDockStopsAndSavesAMeetingOnceItsSlowMicrophoneDeliversAudio() async throws {
        hardware.requireConnection()
        XCTAssertTrue(meeting.start(title: "Slow headset"))
        await wait("the meeting to show connecting") { meeting.isConnecting }
        await wait("the microphone to open") { hardware.captures.count == 1 }
        hardware.captures[0].feed(seconds: 2)
        await wait("the meeting's clock to start") { meeting.startedAt != nil }

        let status = DictationDockStatus.startedMeeting(isConnecting: meeting.isConnecting)
        XCTAssertEqual(status, .meeting(0))
        try XCTUnwrap(dock(status).buttons.first).performClick(nil)

        await wait("the meeting to be saved") { meeting.state == .idle && queued.count == 1 }
        XCTAssertNil(meeting.issue)
        XCTAssertEqual(queued.first?.title, "Slow headset")
        XCTAssertEqual(files(), [try XCTUnwrap(queued.first).url.lastPathComponent])
    }

    /// A dictation that is connecting has nothing to stop from the dock.
    func testTheDockIgnoresAPressWhileADictationConnects() async throws {
        XCTAssertTrue(meeting.start(title: "Untouched"))
        await wait("the meeting's clock to start") { meeting.startedAt != nil }
        let host = dock(.connecting)
        let record = try XCTUnwrap(host.buttons.first)
        XCTAssertFalse(record.isEnabled)
        record.performClick(nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(meeting.isRecording, "A disabled control reaches nothing")
        meeting.cancel()
    }

    func testCancellingAMeetingDiscardsIt() async {
        XCTAssertTrue(meeting.start(title: "Cancelled"))
        await wait("the meeting's clock to start") { meeting.startedAt != nil }
        hardware.captures[0].feed(seconds: 2)
        meeting.cancel()
        XCTAssertEqual(meeting.state, .idle)
        await wait("the capture to close") { hardware.captures[0].finishCount == 1 }
        XCTAssertEqual(files(), [])
        XCTAssertTrue(queued.isEmpty)
    }

    func testAMeetingWithNoMicrophoneOrABusyRecorderSaysWhy() async {
        let other = UUID()
        XCTAssertTrue(recorder.startRecording(sessionID: other))
        XCTAssertFalse(meeting.start(title: "Busy"))
        XCTAssertEqual(meeting.issue, .failed("Another recording is already starting or active."))
        recorder.cancelRecording(sessionID: other)

        hardware.removeMicrophone()
        meeting.clearError()
        XCTAssertFalse(meeting.start(title: "No microphone"))
        XCTAssertEqual(meeting.issue, .failed("No microphone is available. Choose a microphone and try again."))
        XCTAssertEqual(meeting.statusLabel, "Meeting failed — open WorkFlow for details")
    }

    func testAMicrophoneThatDeclinesFailsTheMeeting() async {
        hardware.failStandardCapture(with: StandardCaptureError.declined)
        XCTAssertTrue(meeting.start(title: "Declined"))
        await wait("the meeting to fail") { meeting.issue != nil }
        XCTAssertEqual(meeting.state, .idle)
        XCTAssertEqual(meeting.issue, .failed("The microphone could not start recording: The microphone declined the recording request."))
    }
}
