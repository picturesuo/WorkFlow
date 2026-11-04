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
    case recordingCutShort
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
    /// Esc after the recording stopped: finish into History, paste nothing.
    private var isDeliveryCancelled = false
    /// The capture stopped on its own; the audio until then is still delivered.
    private var isCaptureCutShort = false
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

        recorder.captureStopped
            .receive(on: RunLoop.main)
            .sink { [weak self] sessionID in
                guard let self, self.recorderSessionID == sessionID else { return }
                self.isCaptureCutShort = true
                self.startDecoding()
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
        isCaptureCutShort = false
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
                        targetBundleID: self.pasteTarget?.bundleID,
                        captureOrigin: .live
                    )
                }
            }
            showBusyMessage()
            return
        }
        
        state = .decoding
        let recordingStartedAt = self.recordingStartedAt
        // Processing is timed from the moment the person stopped speaking.
        let stoppedAt = ContinuousClock.now
        
        Task { [weak self] in
            guard let self = self else { return }
            let generation = self.dictationGeneration ?? self.latestDictationGate.begin()
            
            if let tempURL = await self.recorder.stopRecording(sessionID: sessionID) {
                await self.finishDictation(
                    audioAt: tempURL,
                    generation: generation,
                    recordingStartedAt: recordingStartedAt,
                    stoppedAt: stoppedAt
                )
            } else {
                print("!!! Not found record url !!!")
                self.finishDecoding()
            }
        }
    }

    /// Transcribes, cleans up, saves, and delivers one stopped dictation.
    /// `stoppedAt` times processing to ready text; without it, none is claimed.
    func finishDictation(
        audioAt tempURL: URL,
        generation: UInt64,
        recordingStartedAt: Date?,
        stoppedAt: ContinuousClock.Instant? = nil
    ) async {
        let duration = await AudioUtil.audioDuration(url: tempURL)
        do {
            print("start decoding...")
            let rawText = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())
            
            if rawText.isEmpty {
                try? FileManager.default.removeItem(at: tempURL)
                print("No speech detected, dictation discarded")
            } else {
                let plan = cleanupPipeline.selectedPlan()
                self.isFinalizing = true
                let cleanup = await self.cleanupPipeline.finalize(
                    rawText,
                    targetBundleID: self.pasteTarget?.bundleID,
                    filterPlan: plan
                )
                self.isFinalizing = false

                let text = cleanup.text
                guard !text.isEmpty else {
                    try? FileManager.default.removeItem(at: tempURL)
                    print("Cleanup produced an empty dictation; discarded")
                    self.finishDecoding()
                    return
                }
                let processingSeconds = stoppedAt.map { SpeakingEfficiency.seconds($0.duration(to: .now)) }

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
                    cleanupFilterWritesDigits: cleanup.customFilterWritesDigits,
                    cleanupFilterReason: cleanup.filterReason,
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
                let isCurrent = !isDeliveryCancelled && self.latestDictationGate.claimIfCurrent(generation)
                let disposition: DictationDisposition = isCurrent
                    ? (delivery ?? deliver)(text)
                    : isDeliveryCancelled ? .cancelled : .staleSkipped
                let attemptedDelivery = [.pasteSent, .pasteFailed, .copiedOnly].contains(disposition)
                let source = DictationSource(
                    recordingID: recordingId,
                    recordingStartedAt: recordingStartedAt,
                    recognizerText: rawText,
                    cleanup: cleanup,
                    fallbackFilter: plan.provisionalFilter,
                    disposition: disposition,
                    insertedText: attemptedDelivery ? Self.applyPostProcessing(text) : nil,
                    captureOrigin: .live,
                    processingSeconds: processingSeconds
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
            let plan = cleanupPipeline.selectedPlan()
            _ = await recordingStore.addFailedDictation(
                audioAt: tempURL,
                error: error,
                duration: duration,
                selectedFilter: plan.provisionalFilter,
                autoConfig: plan.autoConfig,
                cleanupRequested: cleanupPipeline.cleanupRequested(targetBundleID: pasteTarget?.bundleID),
                targetBundleID: pasteTarget?.bundleID,
                recordingStartedAt: recordingStartedAt,
                keepAudio: recorder.keepTemporaryRecording
            )
            // A newer dictation owns the indicator, and a cancelled one has none.
            if latestDictationGate.isCurrent(generation), !isDeliveryCancelled {
                showAutoDismissingMessage(.transcriptionFailed)
                return
            }
        }
        
        finishDecoding()
    }

    /// Hides the indicator, first saying so briefly if the capture stopped
    /// on its own and this dictation still owns the indicator.
    private func finishDecoding() {
        if isCaptureCutShort, !isDeliveryCancelled {
            showAutoDismissingMessage(.recordingCutShort)
        } else {
            delegate?.didFinishDecoding(self)
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
        guard let sessionID = recorderSessionID else {
            // The recording already stopped: its words still reach History.
            isDeliveryCancelled = true
            return
        }
        recorderSessionID = nil
        recorder.cancelRecording(sessionID: sessionID)
    }
}

/// The live dot: vermilion with a soft glow, still when Reduce Motion is on.
struct RecordingIndicator: View {
    let isBlinking: Bool
    @WFReduceMotion private var reduceMotion

    var body: some View {
        Circle()
            .fill(ThemePalette.signal(.dark))
            .frame(width: 8, height: 8)
            .background(
                Circle()
                    .fill(ThemePalette.signal(.dark).opacity(0.4))
                    .frame(width: 13, height: 13)
                    .blur(radius: 2)
                    .opacity(isBlinking && !reduceMotion ? 0.2 : 1)
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: isBlinking)
            .accessibilityHidden(true)
    }
}

/// Recent microphone levels as rounded bars, newest on the right, so the
/// capsule shows the voice it hears. Silence leaves short, even bars.
struct IndicatorWaveform: View {
    let levels: [CGFloat]
    var color: Color = BrandPalette.ivory
    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 2.5
    static let minHeight: CGFloat = 3
    static let maxHeight: CGFloat = 18
    @WFReduceMotion private var reduceMotion

    static func width(bars: Int) -> CGFloat {
        CGFloat(bars) * barWidth + CGFloat(max(bars - 1, 0)) * spacing
    }

    var body: some View {
        HStack(alignment: .center, spacing: Self.spacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(color.opacity(0.55 + 0.45 * Double(index + 1) / Double(max(levels.count, 1))))
                    .frame(width: Self.barWidth,
                           height: Self.minHeight + (Self.maxHeight - Self.minHeight) * min(max(level, 0), 1))
            }
        }
        .frame(width: Self.width(bars: levels.count), height: Self.maxHeight)
        .animation(reduceMotion ? nil : WFMotion.level, value: levels)
        .accessibilityHidden(true)
    }
}

/// The waveform fed by the shared meter; only this view redraws at its rate.
struct LiveIndicatorWaveform: View {
    @ObservedObject private var meter = InputLevelMeter.shared

    var body: some View {
        IndicatorWaveform(levels: meter.history)
    }
}

/// While transcribing, the bars settle into a slow travelling wave. With
/// Reduce Motion they hold still at a gentle slope.
struct IndicatorProcessingWave: View {
    var bars = 5
    @WFReduceMotion private var reduceMotion

    static func levels(bars: Int, at time: TimeInterval) -> [CGFloat] {
        (0..<bars).map { index in
            let phase: Double = time * 2 * .pi * 0.8 - Double(index) * 0.75
            let level: Double = 0.35 + 0.3 * sin(phase)
            return CGFloat(level)
        }
    }

    var body: some View {
        if reduceMotion {
            IndicatorWaveform(levels: (0..<bars).map { CGFloat(0.2 + 0.1 * Double($0 % 3)) })
        } else {
            TimelineView(.animation) { context in
                IndicatorWaveform(levels: Self.levels(bars: bars, at: context.date.timeIntervalSinceReferenceDate))
            }
        }
    }
}

struct CancelConfirmationBar: View {
    @State private var progress: CGFloat = 1
    @WFReduceMotion private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(BrandPalette.amber)
                .frame(width: geo.size.width * progress, height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .padding(.horizontal, 18)
        .padding(.bottom, 3)
        .onAppear {
            // The bar is the countdown; with Reduce Motion it stays full and
            // the words carry the meaning.
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: IndicatorViewModel.cancelConfirmationWindow)) {
                progress = 0
            }
        }
    }
}

/// The capsule beside the caret. It is always charcoal with ivory type,
/// so it reads the same over any document, in light or dark mode.
struct IndicatorWindow: View {
    /// Geometry shared with IndicatorWindowManager. The panel must be larger
    /// than the card: everything drawn outside the window bounds is cut off,
    /// so the appear offset (moves the card down) and the spring overshoot
    /// need margins, otherwise the card edges are visibly clipped mid-animation.
    static let cardSize = CGSize(width: 224, height: 40)
    static let windowSize = CGSize(width: 256, height: 96)
    static let appearOffset: CGFloat = 20
    static let appearInitialScale: CGFloat = 0.5
    /// Room for words beside the leading glyph and the trailing clock.
    static let horizontalPadding: CGFloat = 16

    @ObservedObject var viewModel: IndicatorViewModel

    private static let ivory = BrandPalette.ivory
    private static let secondaryIvory = BrandPalette.ivory.opacity(0.62)

    /// What the capsule says for each message state; nil while recording,
    /// connecting, or transcribing, which draw live content instead.
    static func message(for state: RecordingState) -> (symbol: String, text: String)? {
        switch state {
        case .busy: ("hourglass", "Processing…")
        case .noMicrophone: ("mic.slash", "No microphone")
        case .recordingFailed: ("exclamationmark.triangle", "Recording failed")
        case .recordingCutShort: ("exclamationmark.triangle", "Recording cut short")
        case .transcriptionFailed: ("exclamationmark.triangle", "Transcription failed")
        case .pasteFailed: ("doc.on.clipboard", "Copied, not pasted")
        case .clipboardFailed: ("tray.full", "Not pasted, in History")
        case .idle, .connecting, .recording, .decoding: nil
        }
    }

    var body: some View {
        let shape = Capsule(style: .continuous)

        content
            .padding(.horizontal, Self.horizontalPadding)
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            .background {
                shape
                    .fill(BrandPalette.charcoal.opacity(0.92))
                    .background { shape.fill(Material.thinMaterial) }
            }
            .overlay {
                // Lit from above, like the record disc.
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            }
            .overlay(alignment: .bottom) {
                if viewModel.isConfirmingCancel {
                    CancelConfirmationBar()
                }
            }
            .clipShape(shape)
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
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
        // spring runs entirely in the render server on the GPU. Only the small
        // waveform redraws while recording.
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .connecting:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Self.ivory)
                    .frame(width: 16)
                label("Connecting microphone…", color: Self.ivory)
                Spacer(minLength: 0)
            }

        case .recording:
            HStack(spacing: 10) {
                RecordingIndicator(isBlinking: viewModel.isBlinking)
                if viewModel.isConfirmingCancel {
                    label("Press Esc to cancel", color: BrandPalette.amber)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                } else {
                    LiveIndicatorWaveform()
                    label("Listening", color: Self.ivory)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                    elapsed
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.isConfirmingCancel)

        case .decoding:
            HStack(spacing: 10) {
                IndicatorProcessingWave()
                label(viewModel.isFinalizing ? "Refining…" : "Transcribing…", color: Self.ivory)
                Spacer(minLength: 0)
            }

        case .idle:
            EmptyView()

        default:
            if let message = Self.message(for: viewModel.state) {
                HStack(spacing: 10) {
                    Image(systemName: message.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BrandPalette.amber)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    label(message.text, color: BrandPalette.amber)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    /// The running length, ticking once a second; absent until the
    /// recording has a start time.
    @ViewBuilder
    private var elapsed: some View {
        if let startedAt = viewModel.recordingStartedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(WFTime.clock(context.date.timeIntervalSince(startedAt)))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Self.secondaryIvory)
                    .fixedSize()
            }
        }
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
