import Combine
import Foundation

@MainActor
final class MeetingSessionController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(title: String)
        case saving(title: String)
    }

    /// Something the person should know about the last meeting.
    struct Issue: Equatable {
        /// The alert's title.
        let title: String
        let message: String
        /// What the menu bar item says while this waits to be read.
        let menuTitle: String

        static func failed(_ message: String) -> Issue {
            Issue(
                title: "Meeting recording failed",
                message: message,
                menuTitle: "Meeting failed — open \(AppIdentity.productName) for details"
            )
        }

        /// The microphone stopped partway and the audio until then was kept.
        static let stoppedEarly = Issue(
            title: "Meeting recording stopped early",
            message: "The microphone stopped during this meeting. The audio recorded until then is saved in History and is being transcribed.",
            menuTitle: "Meeting stopped early — open \(AppIdentity.productName) for details"
        )
    }

    static let shared = MeetingSessionController()

    @Published private(set) var state: State = .idle
    @Published private(set) var issue: Issue?
    /// When the current meeting started recording, for the window's clock.
    /// Nil until the microphone delivers audio.
    @Published private(set) var startedAt: Date?
    /// The meeting's microphone was asked to start and has not delivered
    /// audio yet, as a Bluetooth microphone does while it connects.
    @Published private(set) var isConnecting = false
    private var cleanupRequested = false
    private var activeSessionID: UUID?
    private let recorder: AudioRecorder
    private let enqueue: (_ url: URL, _ title: String, _ cleanupRequested: Bool) async -> Void
    private var cancellables = Set<AnyCancellable>()

    /// Nil uses the app's recorder and transcription queue.
    init(
        recorder: AudioRecorder? = nil,
        enqueue: ((_ url: URL, _ title: String, _ cleanupRequested: Bool) async -> Void)? = nil
    ) {
        let recorder = recorder ?? .shared
        self.recorder = recorder
        self.enqueue = enqueue ?? { url, title, cleanupRequested in
            await TranscriptionQueue.shared.addFileToQueue(
                url: url, title: title, mode: .meeting, cleanupRequested: cleanupRequested
            )
        }

        recorder.$isRecording.combineLatest(recorder.$isConnecting)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let sessionID = self.activeSessionID,
                      self.recorder.ownsRecordingSession(sessionID) else { return }
                // Both flags publish in the same main-queue block; read the
                // settled pair.
                self.isConnecting = self.recorder.isConnecting
                if self.recorder.isRecording, self.startedAt == nil {
                    self.startedAt = Date()
                }
            }
            .store(in: &cancellables)

        // The capture stopped on its own, for example when the microphone
        // was unplugged: the meeting ends there and keeps its audio.
        recorder.captureStopped
            .receive(on: RunLoop.main)
            .sink { [weak self] sessionID in
                guard let self, self.activeSessionID == sessionID else { return }
                Task { await self.stop(stoppedEarly: true) }
            }
            .store(in: &cancellables)
    }

    var errorMessage: String? { issue?.message }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isBusy: Bool { state != .idle }

    var isSaving: Bool {
        if case .saving = state { return true }
        return false
    }

    var statusLabel: String {
        if let issue, state == .idle {
            return issue.menuTitle
        }
        return switch state {
        case .idle: "Start meeting"
        case .recording: "Stop & save meeting"
        case .saving: "Saving meeting…"
        }
    }

    static func defaultTitle(now: Date = Date()) -> String {
        "Meeting \(now.formatted(date: .abbreviated, time: .shortened))"
    }

    @discardableResult
    func start(title: String, cleanupRequested: Bool? = nil) -> Bool {
        guard state == .idle else { return false }
        guard recorder.hasActiveMicrophone else {
            fail("No microphone is available. Choose a microphone and try again.")
            return false
        }
        let sessionID = UUID()
        let accepted = recorder.startRecording(sessionID: sessionID, purpose: .meeting, completion: { [weak self] startError in
            guard let startError else { return }
            Task { @MainActor in
                guard self?.activeSessionID == sessionID else { return }
                self?.fail("The microphone could not start recording: \(startError)")
            }
        })
        guard accepted else {
            fail("Another recording is already starting or active.")
            return false
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        issue = nil
        activeSessionID = sessionID
        self.cleanupRequested = cleanupRequested ?? AppPreferences.shared.meetingCleanupEnabled
        state = .recording(title: normalizedTitle.isEmpty ? Self.defaultTitle() : normalizedTitle)
        startedAt = nil
        isConnecting = false
        return true
    }

    func stop(cleanupRequested: Bool? = nil) async {
        await stop(cleanupRequested: cleanupRequested, stoppedEarly: false)
    }

    /// `stoppedEarly` says the capture ended on its own, so the saved meeting
    /// is shorter than the person meant it to be.
    private func stop(cleanupRequested: Bool? = nil, stoppedEarly: Bool) async {
        guard case .recording(let title) = state, let sessionID = activeSessionID else { return }
        activeSessionID = nil
        startedAt = nil
        isConnecting = false
        state = .saving(title: title)

        guard let url = await recorder.stopRecording(sessionID: sessionID) else {
            fail(stoppedEarly
                ? "The microphone stopped before any usable audio was captured."
                : "No usable audio was captured. The recording may have been too short, or the microphone could not start.")
            return
        }

        await enqueue(url, title, cleanupRequested ?? self.cleanupRequested)
        self.cleanupRequested = false
        if stoppedEarly {
            issue = .stoppedEarly
        }
        state = .idle
    }

    func cancel() {
        guard isBusy else { return }
        if let sessionID = activeSessionID {
            recorder.cancelRecording(sessionID: sessionID)
        }
        activeSessionID = nil
        startedAt = nil
        isConnecting = false
        cleanupRequested = false
        state = .idle
    }

    func clearError() {
        issue = nil
    }

    private func fail(_ message: String) {
        activeSessionID = nil
        startedAt = nil
        isConnecting = false
        cleanupRequested = false
        issue = .failed(message)
        state = .idle
    }
}
