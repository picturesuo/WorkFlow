import Foundation

@MainActor
final class MeetingSessionController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(title: String)
        case saving(title: String)
    }

    static let shared = MeetingSessionController()

    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage: String?
    private var cleanupRequested = false
    private var activeSessionID: UUID?

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
        if errorMessage != nil, state == .idle {
            return "Meeting failed — open \(AppIdentity.productName) for details"
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
        guard MicrophoneService.shared.getActiveMicrophone() != nil else {
            fail("No microphone is available. Choose a microphone and try again.")
            return false
        }
        let sessionID = UUID()
        let accepted = AudioRecorder.shared.startRecording { [weak self] startError in
            guard let startError else { return }
            Task { @MainActor in
                guard self?.activeSessionID == sessionID else { return }
                self?.fail("The microphone could not start recording: \(startError)")
            }
        }
        guard accepted else {
            fail("Another recording is already starting or active.")
            return false
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        activeSessionID = sessionID
        self.cleanupRequested = cleanupRequested ?? AppPreferences.shared.meetingCleanupEnabled
        state = .recording(title: normalizedTitle.isEmpty ? Self.defaultTitle() : normalizedTitle)
        return true
    }

    func stop(cleanupRequested: Bool? = nil) async {
        guard case .recording(let title) = state else { return }
        activeSessionID = nil
        state = .saving(title: title)

        guard let url = await AudioRecorder.shared.stopRecording() else {
            fail("No usable audio was captured. The recording may have been too short, or the microphone could not start.")
            return
        }

        await TranscriptionQueue.shared.addFileToQueue(
            url: url,
            title: title,
            mode: .meeting,
            cleanupRequested: cleanupRequested ?? self.cleanupRequested
        )
        self.cleanupRequested = false
        state = .idle
    }

    func cancel() {
        guard isBusy else { return }
        AudioRecorder.shared.cancelRecording()
        activeSessionID = nil
        cleanupRequested = false
        state = .idle
    }

    func clearError() {
        errorMessage = nil
    }

    private func fail(_ message: String) {
        activeSessionID = nil
        cleanupRequested = false
        errorMessage = message
        state = .idle
    }
}
