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
    @Published var isConfirmingCancel = false
    @Published private(set) var isFinalizing = false
    @Published var recorder: AudioRecorder = .shared
    
    var recordingStartedAt: Date?
    
    var delegate: IndicatorViewDelegate?
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
    
    func cleanup() {
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

/// The live dot: a small steady vermilion point, the capsule's only accent.
/// It does not pulse; the waveform beside it is what moves with the voice.
struct RecordingIndicator: View {
    static let diameter: CGFloat = 6

    var body: some View {
        Circle()
            .fill(ThemePalette.signalText(.dark))
            .frame(width: Self.diameter, height: Self.diameter)
            .accessibilityHidden(true)
    }
}

/// Recent microphone levels as thin rounded bars, newest on the right, so
/// the capsule shows the voice it hears. Silence leaves short, even bars.
struct IndicatorWaveform: View {
    let levels: [CGFloat]
    var color: Color = BrandPalette.ivory
    static let barWidth: CGFloat = 2
    static let spacing: CGFloat = 2
    static let minHeight: CGFloat = 2
    static let maxHeight: CGFloat = 12
    @WFReduceMotion private var reduceMotion

    static func width(bars: Int) -> CGFloat {
        CGFloat(bars) * barWidth + CGFloat(max(bars - 1, 0)) * spacing
    }

    var body: some View {
        HStack(alignment: .center, spacing: Self.spacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(color.opacity(0.4 + 0.3 * Double(index + 1) / Double(max(levels.count, 1))))
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
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
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

/// The small capsule beside the caret: a quiet charcoal pill with ivory
/// type, so it reads the same over any document in light or dark mode.
/// Listening is only a steady dot, a thin waveform, and the clock; words
/// appear only for states that need them. It hugs its content, and the user
/// can drag it anywhere (IndicatorWindowManager keeps where they put it).
struct IndicatorWindow: View {
    /// Geometry shared with IndicatorWindowManager. `cardSize` is the widest
    /// the capsule may grow and its fixed height. The panel is only the
    /// capsule plus `panelPadding` on every side: enough for the soft shadow
    /// and the small appear rise, so the clickable panel stays as close to
    /// the visible pill as the drawing allows. The manager resizes the panel
    /// to the capsule's width as it changes.
    static let cardSize = CGSize(width: 224, height: 32)
    static let panelPadding: CGFloat = 12
    static let shadowRadius: CGFloat = 6
    static let shadowOffset: CGFloat = 2
    /// The panel at the capsule's widest.
    static let windowSize = windowSize(forCardWidth: cardSize.width)
    static let appearOffset: CGFloat = 4
    static let appearInitialScale: CGFloat = 0.92

    static func windowSize(forCardWidth width: CGFloat) -> CGSize {
        CGSize(width: min(width, cardSize.width) + 2 * panelPadding, height: cardSize.height + 2 * panelPadding)
    }
    /// Room inside the pill before the first and after the last element.
    static let horizontalPadding: CGFloat = 12
    /// Between the elements inside the pill.
    static let spacing: CGFloat = 8
    static let font = Font.system(size: 12, weight: .medium)
    static let clockFont = Font.system(size: 11.5, weight: .regular).monospacedDigit()
    /// The pill's fill over whatever is behind it.
    static let fillOpacity: Double = 0.82
    /// Words and their quieter companion, the clock.
    static let textOpacity: Double = 0.88
    static let clockOpacity: Double = 0.62
    static let dragHint = "Drag to move. Double-click to reset its position for the next dictation."

    @ObservedObject var viewModel: IndicatorViewModel
    /// Told the capsule's drawn width whenever it changes.
    var onCardWidthChange: ((CGFloat) -> Void)? = nil

    private static let ivory = BrandPalette.ivory.opacity(textOpacity)
    private static let secondaryIvory = BrandPalette.ivory.opacity(clockOpacity)

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

    /// What VoiceOver reads for the capsule in each state.
    static func accessibilityLabel(for state: RecordingState, isFinalizing: Bool, isConfirmingCancel: Bool) -> String {
        switch state {
        case .connecting: "Connecting microphone"
        case .recording: isConfirmingCancel ? "Press Escape to cancel" : "Listening"
        case .decoding: isFinalizing ? "Refining" : "Transcribing"
        case .idle: ""
        default: message(for: state)?.text ?? ""
        }
    }

    var body: some View {
        let shape = Capsule(style: .continuous)

        content
            .padding(.horizontal, Self.horizontalPadding)
            .frame(height: Self.cardSize.height)
            .frame(maxWidth: Self.cardSize.width)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                shape
                    .fill(BrandPalette.charcoal.opacity(Self.fillOpacity))
                    .background { shape.fill(Material.thinMaterial) }
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .overlay(alignment: .bottom) {
                if viewModel.isConfirmingCancel {
                    CancelConfirmationBar()
                }
            }
            .clipShape(shape)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                onCardWidthChange?(width)
            }
            .shadow(color: Color.black.opacity(0.18), radius: Self.shadowRadius, y: Self.shadowOffset)
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(
                for: viewModel.state, isFinalizing: viewModel.isFinalizing, isConfirmingCancel: viewModel.isConfirmingCancel
            ))
            .accessibilityHint(Self.dragHint)
            // Fills the panel, whose size the manager sets from the reported
            // width; the capsule is always centered in it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            HStack(spacing: Self.spacing) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Self.ivory)
                    .frame(width: 12)
                label("Connecting…", color: Self.ivory)
            }

        case .recording:
            HStack(spacing: Self.spacing) {
                RecordingIndicator()
                if viewModel.isConfirmingCancel {
                    label("Press Esc to cancel", color: BrandPalette.amber)
                        .transition(.opacity)
                } else {
                    LiveIndicatorWaveform()
                        .transition(.opacity)
                    elapsed
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.isConfirmingCancel)

        case .decoding:
            HStack(spacing: Self.spacing) {
                IndicatorProcessingWave()
                label(viewModel.isFinalizing ? "Refining…" : "Transcribing…", color: Self.ivory)
            }

        case .idle:
            EmptyView()

        default:
            if let message = Self.message(for: viewModel.state) {
                HStack(spacing: Self.spacing) {
                    Image(systemName: message.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(BrandPalette.amber)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    label(message.text, color: BrandPalette.amber)
                }
            }
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Self.font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    /// The running length, ticking once a second; absent until the
    /// recording has a start time.
    @ViewBuilder
    private var elapsed: some View {
        if let startedAt = viewModel.recordingStartedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(WFTime.clock(context.date.timeIntervalSince(startedAt)))
                    .font(Self.clockFont)
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
