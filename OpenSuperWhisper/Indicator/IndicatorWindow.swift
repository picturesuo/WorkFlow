import Cocoa
import Combine
import SwiftUI

enum RecordingState {
    case idle
    case connecting
    case recording
    case decoding
    case busy
    case noMicrophone
    case recordingFailed
    case transcriptionFailed
    case pasteFailed
    case clipboardFailed
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    
    func didFinishDecoding(_ viewModel: IndicatorViewModel)
}

@MainActor
class IndicatorViewModel: ObservableObject {
    static let cancelConfirmationThreshold: TimeInterval = 10.0
    static let cancelConfirmationWindow: TimeInterval = 5.0
    
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var isConfirmingCancel = false
    @Published private(set) var isFinalizing = false
    @Published var recorder: AudioRecorder = .shared
    
    var recordingStartedAt: Date?
    
    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
    private var confirmCancelTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    private let recordingStore: RecordingStore
    private let transcriptionService: TranscriptionService
    // Resolved on first use: the shared queue loads the speech engine.
    private lazy var transcriptionQueue: TranscriptionQueue = .shared
    private let cleanupPipeline: TranscriptCleanupPipeline
    private let latestDictationGate: LatestDictationGate
    private var dictationGeneration: UInt64?
    var recorderSessionID: UUID?
    private let pasteTarget: PasteTarget?
    private let delivery: ((String) -> DictationDisposition)?
    
    init(
        pasteTarget: PasteTarget? = nil,
        latestDictationGate: LatestDictationGate? = nil,
        transcriptionService: TranscriptionService? = nil,
        recordingStore: RecordingStore? = nil,
        cleanupPipeline: TranscriptCleanupPipeline? = nil,
        delivery: ((String) -> DictationDisposition)? = nil
    ) {
        self.recordingStore = recordingStore ?? .shared
        self.transcriptionService = transcriptionService ?? .shared
        self.cleanupPipeline = cleanupPipeline ?? .shared
        self.latestDictationGate = latestDictationGate ?? .shared
        self.pasteTarget = pasteTarget
        self.delivery = delivery
        
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self, let sessionID = self.recorderSessionID,
                      self.recorder.ownsRecordingSession(sessionID) else { return }
                if isConnecting {
                    self.state = .connecting
                    self.stopBlinking()
                }
            }
            .store(in: &cancellables)
        
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self, let sessionID = self.recorderSessionID,
                      self.recorder.ownsRecordingSession(sessionID) else { return }
                if isRecording {
                    self.state = .recording
                    self.startBlinking()
                }
            }
            .store(in: &cancellables)
    }
    
    var isTranscriptionBusy: Bool {
        transcriptionService.isTranscribing || transcriptionQueue.isProcessing || isFinalizing
    }
    
    func showBusyMessage() {
        showAutoDismissingMessage(.busy)
    }

    private func showAutoDismissingMessage(_ message: RecordingState) {
        state = message

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.delegate?.didFinishDecoding(self)
            }
        }
    }

    func startRecording() {
        if MeetingSessionController.shared.isRecording {
            showBusyMessage()
            return
        }

        if isTranscriptionBusy {
            showBusyMessage()
            return
        }

        // getActiveMicrophone() only reads the cached currentMicrophone, so
        // this guard costs no CoreAudio HAL round-trip on the main thread.
        guard MicrophoneService.shared.getActiveMicrophone() != nil else {
            showAutoDismissingMessage(.noMicrophone)
            return
        }
        
        // Optimistically assume recording: querying the microphone here costs
        // CoreAudio HAL round-trips on the main thread right before the appear
        // animation. The recorder resolves the real state on its own queue and
        // publishes isConnecting/isRecording, which the sinks above translate
        // into .connecting/.recording.
        let sessionID = UUID()
        guard recorder.startRecording(sessionID: sessionID, completion: { [weak self] startError in
            guard startError != nil else { return }
            Task { @MainActor in
                guard let self, self.recorderSessionID == sessionID else { return }
                self.recorderSessionID = nil
                self.stopBlinking()
                self.showAutoDismissingMessage(.recordingFailed)
            }
        }) else {
            showBusyMessage()
            return
        }

        // Starting a newer recording immediately retires every older async
        // transcription/cleanup result, even before this recording is stopped.
        recorderSessionID = sessionID
        dictationGeneration = latestDictationGate.begin()
        state = .recording
        startBlinking()
        recordingStartedAt = Date()
    }
    
    func handleCancelRequest() -> Bool {
        if AppPreferences.shared.ignoreEscWhileRecording,
           state == .recording || state == .connecting {
            resetCancelConfirmation()
            return false
        }

        guard state == .recording,
              !AppPreferences.shared.escCancelWithoutConfirmation,
              !isConfirmingCancel,
              let startedAt = recordingStartedAt,
              Date().timeIntervalSince(startedAt) >= Self.cancelConfirmationThreshold
        else {
            return true
        }
        
        isConfirmingCancel = true
        confirmCancelTimer?.invalidate()
        confirmCancelTimer = Timer.scheduledTimer(withTimeInterval: Self.cancelConfirmationWindow, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.resetCancelConfirmation()
            }
        }
        return false
    }
    
    private func resetCancelConfirmation() {
        confirmCancelTimer?.invalidate()
        confirmCancelTimer = nil
        isConfirmingCancel = false
    }
    
    func startDecoding() {
        // A second stop request (double hotkey press, hold-mode key-up) must not
        // restart decoding or hide the window while transcription is in flight.
        guard state == .recording || state == .connecting else { return }
        resetCancelConfirmation()
        guard let sessionID = recorderSessionID else { return }
        recorderSessionID = nil
        stopBlinking()
        
        if transcriptionQueue.isProcessing {
            // Queue work (imports, meetings, regenerations) can hold the engine
            // for minutes: keep the user's audio and queue it instead of deleting
            // it. The queue never pastes. A dictation stopped while an older
            // dictation is still transcribing does not come here: starting it
            // already retired the older one, so queueing it would paste neither.
            // Transcription is serialized, so it waits and is delivered.
            Task { [weak self] in
                guard let self = self else { return }
                if let tempURL = await self.recorder.stopRecording(sessionID: sessionID) {
                    let rule = TargetAppRuleStore.rule(for: self.pasteTarget?.bundleID)
                    await self.transcriptionQueue.addFileToQueue(
                        url: tempURL,
                        cleanupRequested: TargetAppRuleStore.cleanupEnabled(
                            rule: rule,
                            globalDefault: AppPreferences.shared.bedrockCleanupEnabled
                        ),
                        targetBundleID: self.pasteTarget?.bundleID
                    )
                }
            }
            showBusyMessage()
            return
        }
        
        state = .decoding
        let recordingStartedAt = self.recordingStartedAt
        
        Task { [weak self] in
            guard let self = self else { return }
            let generation = self.dictationGeneration ?? self.latestDictationGate.begin()
            
            if let tempURL = await self.recorder.stopRecording(sessionID: sessionID) {
                await self.finishDictation(audioAt: tempURL, generation: generation, recordingStartedAt: recordingStartedAt)
            } else {
                print("!!! Not found record url !!!")
                
                await MainActor.run {
                    self.delegate?.didFinishDecoding(self)
                }
            }
        }
    }

    /// Transcribes, cleans up, saves, and delivers one stopped dictation.
    func finishDictation(audioAt tempURL: URL, generation: UInt64, recordingStartedAt: Date?) async {
        let duration = await AudioUtil.audioDuration(url: tempURL)
        do {
            print("start decoding...")
            let rawText = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())
            
            if rawText.isEmpty {
                try? FileManager.default.removeItem(at: tempURL)
                print("No speech detected, dictation discarded")
            } else {
                let filter = cleanupPipeline.selectedFilter()
                self.isFinalizing = true
                let cleanup = await self.cleanupPipeline.finalize(
                    rawText,
                    targetBundleID: self.pasteTarget?.bundleID,
                    filterOverride: filter
                )
                self.isFinalizing = false

                let text = cleanup.text
                guard !text.isEmpty else {
                    try? FileManager.default.removeItem(at: tempURL)
                    print("Cleanup produced an empty dictation; discarded")
                    self.delegate?.didFinishDecoding(self)
                    return
                }

                let timestamp = Date()
                let recordingId = UUID()
                let fileName = AudioRecorder.recordingFileName(id: recordingId)
                var newRecording = Recording(
                    id: recordingId,
                    timestamp: timestamp,
                    fileName: fileName,
                    transcription: text,
                    duration: duration,
                    status: .completed,
                    progress: 1.0,
                    sourceFileURL: nil,
                    cleanupSource: cleanup.source,
                    cleanupInputTokens: cleanup.inputTokens,
                    cleanupOutputTokens: cleanup.outputTokens,
                    cleanupModelID: cleanup.modelID,
                    cleanupRequested: cleanup.source != .disabled,
                    targetBundleID: self.pasteTarget?.bundleID,
                    cleanupMode: cleanup.cleanupMode,
                    cleanupFilterName: cleanup.customFilterName,
                    cleanupFilterInstructions: cleanup.customFilterInstructions,
                    rawTokenEstimate: cleanup.rawTokenEstimate,
                    finalTokenEstimate: cleanup.finalTokenEstimate,
                    tokenEstimatorID: cleanup.tokenEstimatorID
                )
                
                // A failed move must not lose the transcript: it is still
                // delivered and saved, with whatever audio is left.
                let audioURL = recorder.keepTemporaryRecording(tempURL, at: newRecording.url)
                if audioURL != newRecording.url {
                    newRecording.sourceFileURL = audioURL?.path
                }

                // claimIfCurrent is process-wide and one-shot, so an older
                // session finishing late cannot paste over a newer dictation.
                let isCurrent = self.latestDictationGate.claimIfCurrent(generation)
                let disposition = isCurrent ? (delivery ?? deliver)(text) : .staleSkipped
                let attemptedDelivery = [.pasteSent, .pasteFailed, .copiedOnly].contains(disposition)
                let source = DictationSource(
                    recordingID: recordingId,
                    recordingStartedAt: recordingStartedAt,
                    recognizerText: rawText,
                    cleanup: cleanup,
                    fallbackFilter: filter,
                    disposition: disposition,
                    insertedText: attemptedDelivery ? Self.applyPostProcessing(text) : nil
                )
                await MainActor.run {
                    self.recordingStore.addRecording(newRecording, source: source)
                }

                guard isCurrent else {
                    print("Saved stale or already-pasted dictation generation \(generation) without pasting")
                    self.delegate?.didFinishDecoding(self)
                    return
                }
                
                guard disposition != .pasteFailed else {
                    let recoveryState: RecordingState =
                        NSPasteboard.general.string(forType: .string) == Self.applyPostProcessing(text)
                        ? .pasteFailed
                        : .clipboardFailed
                    showAutoDismissingMessage(recoveryState)
                    return
                }
                print(
                    "Final transcript source=\(cleanup.source) " +
                    "inputTokens=\(cleanup.inputTokens.map(String.init) ?? "unknown") " +
                    "outputTokens=\(cleanup.outputTokens.map(String.init) ?? "unknown")"
                )
            }
        } catch is CancellationError {
            self.isFinalizing = false
            print("Audio transcription cancelled.")
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            self.isFinalizing = false
            print("Audio transcription failed; the audio is kept in History.")
            _ = await recordingStore.addFailedDictation(
                audioAt: tempURL,
                error: error,
                duration: duration,
                selectedFilter: cleanupPipeline.selectedFilter(),
                cleanupRequested: cleanupPipeline.cleanupRequested(targetBundleID: pasteTarget?.bundleID),
                targetBundleID: pasteTarget?.bundleID,
                recordingStartedAt: recordingStartedAt,
                keepAudio: recorder.keepTemporaryRecording
            )
            // A newer dictation owns the indicator; its own outcome is shown.
            if latestDictationGate.isCurrent(generation) {
                showAutoDismissingMessage(.transcriptionFailed)
                return
            }
        }
        
        await MainActor.run {
            self.delegate?.didFinishDecoding(self)
        }
    }

    /// Delivers the text as the app rule and preferences ask and reports
    /// what was done. A posted Cmd+V is not proof the target inserted it.
    func deliver(_ text: String) -> DictationDisposition {
        guard !text.isEmpty else { return .pasteFailed }
        let finalText = Self.applyPostProcessing(text)
        let prefs = AppPreferences.shared
        let appRule = TargetAppRuleStore.rule(for: pasteTarget?.bundleID)

        switch appRule?.pasteBehavior ?? .appDefault {
        case .never:
            return .savedOnly
        case .copyOnly:
            ClipboardUtil.copyToClipboard(finalText)
            return .copiedOnly
        case .appDefault:
            break
        }

        if prefs.autoPasteTranscription {
            let posted = if prefs.autoCopyToClipboard {
                // Paste and keep in clipboard
                ClipboardUtil.insertTextAndKeepInClipboard(finalText, targetPID: pasteTarget?.pid)
            } else {
                // Paste but restore original clipboard (legacy behavior)
                ClipboardUtil.insertText(finalText, targetPID: pasteTarget?.pid)
            }
            return posted ? .pasteSent : .pasteFailed
        } else if prefs.autoCopyToClipboard {
            // Only copy to clipboard, don't paste
            ClipboardUtil.copyToClipboard(finalText)
            return .copiedOnly
        }
        // If both are false, do nothing
        return .savedOnly
    }
    
    static func applyPostProcessing(_ text: String) -> String {
        guard AppPreferences.shared.addSpaceAfterSentence,
              let lastChar = text.last,
              lastChar.isPunctuation else {
            return text
        }
        return text + " "
    }
    
    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            // Update UI on the main thread
            Task { @MainActor in
                guard let self = self else { return }
                self.isBlinking.toggle()
            }
        }
    }
    
    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }

    func cleanup() {
        stopBlinking()
        resetCancelConfirmation()
        recordingStartedAt = nil
        hideTimer?.invalidate()
        hideTimer = nil
        cancellables.removeAll()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard let sessionID = recorderSessionID else { return }
        recorderSessionID = nil
        recorder.cancelRecording(sessionID: sessionID)
    }
}

struct RecordingIndicator: View {
    let isBlinking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.red.opacity(0.8), Color.red],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 8, height: 8)
            .opacity(isBlinking && !reduceMotion ? 0.3 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: isBlinking)
    }
}

struct CancelConfirmationBar: View {
    @State private var progress: CGFloat = 1
    
    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.orange)
                .frame(width: geo.size.width * progress, height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 3)
        .onAppear {
            withAnimation(.linear(duration: IndicatorViewModel.cancelConfirmationWindow)) {
                progress = 0
            }
        }
    }
}

struct IndicatorWindow: View {
    /// Geometry shared with IndicatorWindowManager. The panel must be larger
    /// than the card: everything drawn outside the window bounds is cut off,
    /// so the appear offset (moves the card down) and the spring overshoot
    /// need margins, otherwise the card edges are visibly clipped mid-animation.
    static let cardSize = CGSize(width: 200, height: 36)
    static let windowSize = CGSize(width: 256, height: 96)
    static let appearOffset: CGFloat = 20
    static let appearInitialScale: CGFloat = 0.5
    
    @ObservedObject var viewModel: IndicatorViewModel
    @Environment(\.colorScheme) private var colorScheme
    
    private var backgroundColor: Color {
        BrandPalette.charcoal.opacity(colorScheme == .dark ? 0.82 : 0.9)
    }
    
    var body: some View {

        let rect = RoundedRectangle(cornerRadius: 24)
        
        VStack(spacing: 12) {
            switch viewModel.state {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(BrandPalette.ivory)
                        .scaleEffect(0.7)
                        .frame(width: 24)
                    
                    Text("Connecting...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .recording:
                HStack(spacing: 8) {
                    RecordingIndicator(isBlinking: viewModel.isBlinking)
                        .frame(width: 24)
                    
                    if viewModel.isConfirmingCancel {
                        Text("Press Esc to cancel")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.orange)
                            .transition(.opacity)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    } else {
                        Text("Recording...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .transition(.opacity)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.2), value: viewModel.isConfirmingCancel)
                
            case .decoding:
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(BrandPalette.ivory)
                        .scaleEffect(0.7)
                        .frame(width: 24)
                    
                    Text(viewModel.isFinalizing ? "Refining..." : "Transcribing...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .busy:
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    Text("Processing...")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .noMicrophone:
                HStack(spacing: 8) {
                    Image(systemName: "mic.slash")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    Text("No microphone")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .recordingFailed:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    Text("Recording failed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .transcriptionFailed:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    Text("Transcription failed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .pasteFailed:
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    Text("Copied, not pasted")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .clipboardFailed:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    Text("Not pasted, in History")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.cardSize.height)
        .background {
            rect
                .fill(backgroundColor)
                .background {
                    rect
                        .fill(Material.thinMaterial)
                }
        }
        .overlay {
            rect
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .overlay(alignment: .bottom) {
            if viewModel.isConfirmingCancel {
                CancelConfirmationBar()
            }
        }
        .clipShape(rect)
        .frame(width: Self.cardSize.width)
        // The ideal size of the root view must match the panel: NSHostingView
        // resizes the window down to SwiftUI's ideal size, and a window sized
        // to the bare card clips the appear offset, bounce overshoot and shadow.
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        // The appear/hide animation is NOT done in SwiftUI on purpose:
        // animating scaleEffect/offset/opacity re-rasterizes the card (material
        // + gradients + shadow) on the CPU every frame and stalls the main
        // thread in CABackingStoreUpdate/wait_for_synchronize (20-60 ms per
        // frame in traces). IndicatorWindowManager animates the hosting view's
        // layer with CASpringAnimation instead: content is drawn once and the
        // spring runs entirely in the render server on the GPU.
    }
}

struct IndicatorWindowPreview: View {
    @StateObject private var recordingVM = {
        let vm = IndicatorViewModel()
//        vm.startRecording()
        return vm
    }()
    
    @StateObject private var decodingVM = {
        let vm = IndicatorViewModel()
        vm.state = .decoding
        return vm
    }()
    
    var body: some View {
        VStack(spacing: 20) {
            IndicatorWindow(viewModel: recordingVM)
            IndicatorWindow(viewModel: decodingVM)
        }
        .padding()
        .frame(height: 200)
        .background(Color(.windowBackgroundColor))
    }
}

#Preview {
    IndicatorWindowPreview()
}
