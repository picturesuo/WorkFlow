//
//  ContentView.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import Combine
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RecordingHistoryModel: ObservableObject {
    typealias Loader = @MainActor (String, Int, Int) async throws -> [Recording]

    @Published var recordings: [Recording] = []
    @Published private(set) var isLoadingMore = false
    @Published private(set) var canLoadMore = true
    @Published private(set) var errorMessage: String?
    private(set) var query = ""

    private let loader: Loader
    private let pageSize: Int
    private var nextOffset = 0
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?

    init(pageSize: Int = 100, loader: @escaping Loader) {
        self.pageSize = pageSize
        self.loader = loader
    }

    @discardableResult
    func search(query: String) -> Task<Void, Never> {
        self.query = query
        recordings = []
        return refresh()
    }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        // Even a refresh of the same query supersedes every older page request.
        generation = UUID()
        loadTask?.cancel()
        isLoadingMore = false
        nextOffset = 0
        canLoadMore = true
        return loadMore()!
    }

    @discardableResult
    func loadMore() -> Task<Void, Never>? {
        guard !isLoadingMore && canLoadMore else { return nil }
        isLoadingMore = true
        errorMessage = nil
        let requestGeneration = generation
        let requestQuery = query
        let offset = nextOffset

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                // An obsolete completion must not hide a newer request's spinner.
                if self.generation == requestGeneration {
                    self.isLoadingMore = false
                    self.loadTask = nil
                }
            }

            do {
                let page = try await self.loader(requestQuery, self.pageSize, offset)
                guard self.generation == requestGeneration else { return }
                if offset == 0 {
                    self.recordings = page
                } else {
                    self.recordings.append(contentsOf: page)
                }
                self.nextOffset = offset + page.count
                self.canLoadMore = page.count == self.pageSize
            } catch {
                guard self.generation == requestGeneration else { return }
                self.errorMessage = "History couldn't load. Try again."
            }
        }
        loadTask = task
        return task
    }
}

@MainActor
class ContentViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var recorder: AudioRecorder = .shared
    @Published var transcriptionService = TranscriptionService.shared
    @Published var transcriptionQueue = TranscriptionQueue.shared
    @Published var recordingStore = RecordingStore.shared
    private let history = RecordingHistoryModel { query, limit, offset in
        if query.isEmpty {
            return try await RecordingStore.shared.fetchRecordings(limit: limit, offset: offset)
        }
        return try await RecordingStore.shared.searchRecordingsAsync(query: query, limit: limit, offset: offset)
    }
    var recordings: [Recording] {
        get { history.recordings }
        set { history.recordings = newValue }
    }
    var isLoadingMore: Bool { history.isLoadingMore }
    var canLoadMore: Bool { history.canLoadMore }
    var historyError: String? { history.errorMessage }
    @Published var recordingDuration: TimeInterval = 0
    @Published var microphoneService = MicrophoneService.shared
    @Published var recordingError: String?
    
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self else { return }
                if isConnecting && self.state != .decoding {
                    self.state = .connecting
                    self.stopDurationTimer()
                    self.recordingDuration = 0
                }
            }
            .store(in: &cancellables)
        
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                if isRecording && self.state != .decoding {
                    self.state = .recording
                    self.startDurationTimerIfNeeded()
                } else if !isRecording && self.state == .recording {
                    self.state = .idle
                    self.stopDurationTimer()
                    self.recordingDuration = 0
                }
            }
            .store(in: &cancellables)
    }
    
    func loadInitialData() {
        refreshHistory()
    }

    func refreshHistory() {
        history.refresh()
    }

    func loadMore() {
        history.loadMore()
    }

    func retryLoading() {
        history.loadMore()
    }

    func search(query: String) {
        history.search(query: query)
    }

    func handleProgressUpdate(id: UUID, transcription: String?, progress: Float, status: RecordingStatus, isRegeneration: Bool?) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            if let transcription = transcription {
                recordings[index].transcription = transcription
            }
            recordings[index].progress = progress
            recordings[index].status = status
            if let isRegeneration = isRegeneration {
                recordings[index].isRegeneration = isRegeneration
            }
        }
    }
    
    func deleteRecording(_ recording: Recording) {
        recordingStore.deleteRecording(recording)
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings.remove(at: index)
        }
    }
    
    func deleteAllRecordings() {
        recordingStore.deleteAllRecordings()
        recordings.removeAll()
    }

    var isRecording: Bool {
        recorder.isRecording
    }
    
    func startRecording() {
        guard !MeetingSessionController.shared.isRecording else { return }
        guard microphoneService.getActiveMicrophone() != nil else { return }

        if microphoneService.isActiveMicrophoneRequiresConnection() {
            state = .connecting
            stopDurationTimer()
            recordingDuration = 0
        } else {
            state = .recording
            recordingStartTime = Date()
            recordingDuration = 0
            startDurationTimerIfNeeded()
        }
        
        guard recorder.startRecording(completion: { [weak self] startError in
            guard let startError else { return }
            Task { @MainActor in
                guard let self else { return }
                self.state = .idle
                self.stopDurationTimer()
                self.recordingDuration = 0
                self.recordingError = startError
            }
        }) else {
            state = .idle
            stopDurationTimer()
            recordingDuration = 0
            return
        }
    }

    func startDecoding() {
        state = .decoding
        stopDurationTimer()
        
        IndicatorWindowManager.shared.hide()

        Task { [weak self] in
            guard let self = self else { return }
            
            if let tempURL = await self.recorder.stopRecording() {
                do {
                    print("start decoding...")
                    let duration = await AudioUtil.audioDuration(url: tempURL)
                    let rawText = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())
                    let cleanup = await TranscriptCleanupPipeline.shared.finalize(rawText)
                    let text = cleanup.text

                    if text.isEmpty {
                        try? FileManager.default.removeItem(at: tempURL)
                        print("No speech detected, dictation discarded")
                    } else {
                        let timestamp = Date()
                        let recordingId = UUID()
                        let fileName = AudioRecorder.recordingFileName(id: recordingId)
                        let newRecording = Recording(
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
                            cleanupMode: cleanup.cleanupMode,
                            rawTokenEstimate: cleanup.rawTokenEstimate,
                            finalTokenEstimate: cleanup.finalTokenEstimate,
                            tokenEstimatorID: cleanup.tokenEstimatorID
                        )

                        try recorder.moveTemporaryRecording(from: tempURL, to: newRecording.url)

                        do {
                            try await self.recordingStore.addRecordingSync(newRecording)
                        } catch {
                            // The move succeeded, but no history row owns this file.
                            try? FileManager.default.removeItem(at: newRecording.url)
                            throw error
                        }

                    }
                } catch {
                    self.recordingError = "The recording could not be transcribed or saved. Please try again."
                    print("Audio-file transcription failed.")
                    try? FileManager.default.removeItem(at: tempURL)
                }

                await MainActor.run {
                    self.state = .idle
                    self.recordingDuration = 0
                }
            } else {
                await MainActor.run {
                    self.state = .idle
                    self.recordingDuration = 0
                }
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
    }
    
    private func startDurationTimerIfNeeded() {
        guard durationTimer == nil else { return }
        if recordingStartTime == nil {
            recordingStartTime = Date()
            recordingDuration = 0
        }
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let startTime = Date()
            Task { @MainActor in
                if let recordingStartTime = self.recordingStartTime {
                    self.recordingDuration = startTime.timeIntervalSince(recordingStartTime)
                }
            }
        }
        RunLoop.main.add(durationTimer!, forMode: .common)
    }

}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @StateObject private var permissionsManager = PermissionsManager()
    @StateObject private var meetingController = MeetingSessionController.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSettingsPresented = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showDeleteConfirmation = false
    @State private var showMeetingNamePrompt = false
    @State private var meetingTitle = MeetingSessionController.defaultTitle()
    @State private var searchTask: Task<Void, Never>? = nil
    @AppStorage("cleanupMode") private var cleanupModeRaw = CleanupMode.everyday.rawValue
    @AppStorage("modifierOnlyHotkey") private var modifierOnlyHotkeyRaw = ModifierKey.fn.rawValue

    private var currentShortcutDescription: String {
        let mouseButton = MouseButton(rawValue: AppPreferences.shared.mouseButtonHotkey) ?? .none
        if mouseButton != .none {
            return mouseButton.shortSymbol
        }
        let modifierKey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        if modifierKey != .none {
            let secondary = ModifierKey(rawValue: AppPreferences.shared.secondaryModifierOnlyHotkey) ?? .none
            if secondary != .none, secondary != modifierKey {
                return "\(modifierKey.shortSymbol) / \(secondary.shortSymbol)"
            }
            return modifierKey.shortSymbol
        } else if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
            return shortcut.description
        }
        return ""
    }
    
    private func performSearch(_ query: String) {
        searchTask?.cancel()
        
        if query.isEmpty {
            debouncedSearchText = ""
            viewModel.search(query: "")
            return
        }
        
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                self.debouncedSearchText = query
                viewModel.search(query: query)
            }
        }
    }

    private var selectedCleanupMode: CleanupMode {
        CleanupMode(rawValue: cleanupModeRaw) ?? .everyday
    }

    private var cleanupModeBinding: Binding<CleanupMode> {
        Binding(
            get: { selectedCleanupMode },
            set: {
                cleanupModeRaw = $0.rawValue
                NotificationCenter.default.post(name: .cleanupModeChanged, object: nil)
            }
        )
    }

    private var requiresInputMonitoring: Bool {
        let modifier = ModifierKey(rawValue: modifierOnlyHotkeyRaw) ?? .none
        return modifier != .none
    }

    var body: some View {
        VStack {
            if permissionsManager.hasCompletedInitialCheck,
               !permissionsManager.isMicrophonePermissionGranted
                || !permissionsManager.isAccessibilityPermissionGranted
            {
                PermissionsView(permissionsManager: permissionsManager)
            } else {
                VStack(spacing: 0) {
                    HistoryHeader(searchText: $searchText, isSearching: !debouncedSearchText.isEmpty) {
                        HStack(spacing: WFSpace.sm) {
                            ToolbarIconButton(
                                systemImage: meetingController.isRecording ? "stop.fill" : "person.2.wave.2.fill",
                                help: meetingController.statusLabel,
                                accessibilityLabel: meetingController.statusLabel,
                                tint: meetingController.isRecording ? .red : .secondary
                            ) {
                                if meetingController.isRecording {
                                    Task { await meetingController.stop() }
                                } else {
                                    meetingTitle = MeetingSessionController.defaultTitle()
                                    showMeetingNamePrompt = true
                                }
                            }
                            .disabled(!meetingController.isRecording && (meetingController.isBusy || viewModel.state != .idle))

                            MicrophonePickerIconView(microphoneService: viewModel.microphoneService)

                            Group {
                                ToolbarIconButton(
                                    systemImage: "trash",
                                    help: "Delete all recordings",
                                    accessibilityLabel: "Delete all recordings"
                                ) {
                                    showDeleteConfirmation = true
                                }
                                .confirmationDialog(
                                    "Delete All Recordings",
                                    isPresented: $showDeleteConfirmation,
                                    titleVisibility: .visible
                                ) {
                                    Button("Delete All", role: .destructive) {
                                        viewModel.deleteAllRecordings()
                                    }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("This deletes every recording, including recordings outside the current search. This cannot be undone.")
                                }
                                .disabled(viewModel.recordings.isEmpty && debouncedSearchText.isEmpty)
                            }

                            ToolbarIconButton(
                                systemImage: "gear",
                                help: "Settings",
                                accessibilityLabel: "Open settings"
                            ) {
                                isSettingsPresented.toggle()
                            }
                        }
                    }
                    .onChange(of: searchText) { _, query in performSearch(query) }

                    if permissionsManager.hasCompletedInitialCheck,
                       requiresInputMonitoring,
                       !permissionsManager.isInputMonitoringPermissionGranted {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Enable Input Monitoring to use \(currentShortcutDescription).")
                                .font(.caption)
                            Spacer()
                            Button("Enable") {
                                permissionsManager.requestInputMonitoringPermissionOrOpenSystemPreferences()
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Enable Input Monitoring")
                        }
                        .padding(.horizontal, WFSpace.md)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: WFRadius.control, style: .continuous)
                                .fill(Color.orange.opacity(0.12))
                        )
                        .padding(.horizontal, WFSpace.lg)
                        .padding(.top, WFSpace.md)
                    }

                    ScrollView {
                        if viewModel.recordings.isEmpty {
                            if viewModel.isLoadingMore {
                                ProgressView("Loading history…")
                                    .frame(maxWidth: .infinity)
                                    .padding(WFSpace.xl)
                            } else if viewModel.historyError == nil {
                                HistoryEmptyState(isSearching: !debouncedSearchText.isEmpty)
                                    .padding(.top, 48)
                            }
                        } else {
                            LazyVStack(spacing: WFSpace.md) {
                                ForEach(viewModel.recordings) { recording in
                                    RecordingRow(
                                        recording: recording,
                                        searchQuery: debouncedSearchText,
                                        onDelete: {
                                            viewModel.deleteRecording(recording)
                                        },
                                        onRegenerate: {
                                            Task {
                                                await TranscriptionQueue.shared.requeueRecording(recording)
                                            }
                                        }
                                    )
                                    .id(recording.id)
                                    .onAppear {
                                        if recording.id == viewModel.recordings.last?.id {
                                            viewModel.loadMore()
                                        }
                                    }
                                }
                                
                                if viewModel.isLoadingMore {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                }
                            }
                            .padding(.horizontal, WFSpace.xl)
                            .padding(.top, WFSpace.xs)
                            .padding(.bottom, WFSpace.xl)
                        }
                    }
                    if let error = viewModel.historyError {
                        VStack(spacing: WFSpace.sm) {
                            Label("Couldn’t load history", systemImage: "exclamationmark.triangle")
                                .font(.subheadline.weight(.medium))
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("Try again") { viewModel.retryLoading() }
                        }
                        .multilineTextAlignment(.center)
                        .padding(WFSpace.lg)
                    }

                    DictationControls(
                        viewModel: viewModel,
                        transcriptionService: viewModel.transcriptionService,
                        transcriptionQueue: viewModel.transcriptionQueue,
                        microphoneService: viewModel.microphoneService,
                        meetingController: meetingController,
                        shortcut: currentShortcutDescription,
                        cleanupMode: cleanupModeBinding
                    )
                }
            }
        }
        .frame(minWidth: 440, idealWidth: 560, minHeight: 460)
        .background(ThemePalette.windowBackground(colorScheme))
        .background(WindowChromeConfigurator())
        .onAppear {
            viewModel.loadInitialData()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingProgressDidUpdateNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let id = userInfo["id"] as? UUID,
                  let progress = userInfo["progress"] as? Float,
                  let status = userInfo["status"] as? RecordingStatus else { return }
            
            let transcription = userInfo["transcription"] as? String
            let isRegeneration = userInfo["isRegeneration"] as? Bool
            
            viewModel.handleProgressUpdate(
                id: id,
                transcription: transcription,
                progress: progress,
                status: status,
                isRegeneration: isRegeneration
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingsDidUpdateNotification)) { _ in
            viewModel.refreshHistory()
        }
        .fileDropHandler()
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
        .alert("Start meeting recording", isPresented: $showMeetingNamePrompt) {
            TextField("Meeting name", text: $meetingTitle)
            Button("Cancel", role: .cancel) {}
            Button("Start") {
                _ = meetingController.start(title: meetingTitle)
            }
        } message: {
            Text("\(AppIdentity.productName) records locally until you stop it. Meeting mode never pastes into another app.")
        }
        .alert(
            "Meeting recording failed",
            isPresented: Binding(
                get: { meetingController.errorMessage != nil },
                set: { if !$0 { meetingController.clearError() } }
            )
        ) {
            Button("OK") { meetingController.clearError() }
        } message: {
            Text(meetingController.errorMessage ?? "The recording could not be saved.")
        }
        .alert(
            "Recording failed",
            isPresented: Binding(
                get: { viewModel.recordingError != nil },
                set: { if !$0 { viewModel.recordingError = nil } }
            )
        ) {
            Button("OK") { viewModel.recordingError = nil }
        } message: {
            Text(viewModel.recordingError ?? "The microphone could not start.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            isSettingsPresented = true
        }
        .onDisappear { searchTask?.cancel() }
    }
}


struct HistoryHeader<Controls: View>: View {
    @Binding var searchText: String
    var isSearching: Bool
    @ViewBuilder let controls: () -> Controls
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WFSpace.lg) {
            HStack(spacing: WFSpace.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ThemePalette.iconAccent(colorScheme))
                Text(AppIdentity.productName).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: WFSpace.sm)
                controls()
            }
            HStack(alignment: .firstTextBaseline) {
                Text(isSearching ? "Search results" : "History")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Spacer()
                Text("Your words, ready to use")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: WFSpace.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcriptions", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search transcriptions")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, WFSpace.md)
            .frame(height: 36)
            .background(ThemePalette.cardBackground(colorScheme), in: RoundedRectangle(cornerRadius: WFRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: WFRadius.control)
                    .stroke(ThemePalette.cardBorder(colorScheme), lineWidth: 1)
            }
        }
        .padding(.horizontal, WFSpace.xl)
        .padding(.top, 28)
        .padding(.bottom, WFSpace.lg)
    }
}

struct HistoryEmptyState: View {
    let isSearching: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: WFSpace.md) {
            Image(systemName: isSearching ? "magnifyingglass" : "waveform")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ThemePalette.iconAccent(colorScheme))
                .frame(width: 60, height: 60)
                .background(ThemePalette.panelSurface(colorScheme), in: RoundedRectangle(cornerRadius: 18))
            Text(isSearching ? "No matching transcriptions" : "Make room for your next thought")
                .font(.headline)
            Text(isSearching ? "Try another word or clear the search." : "Record a dictation, or drop an audio file here.\nYour transcripts will appear in this history.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(WFSpace.lg)
    }
}

private struct DictationControls: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var transcriptionService: TranscriptionService
    @ObservedObject var transcriptionQueue: TranscriptionQueue
    @ObservedObject var microphoneService: MicrophoneService
    @ObservedObject var meetingController: MeetingSessionController
    let shortcut: String
    @Binding var cleanupMode: CleanupMode

    private var status: DictationDockStatus {
        if meetingController.isSaving { return .savingMeeting }
        if meetingController.isRecording { return .meeting }
        if viewModel.state == .decoding { return .transcribing }
        // Stopping dictation must remain available even when another service becomes busy.
        if viewModel.isRecording { return .recording(viewModel.recordingDuration) }
        if viewModel.state == .connecting || viewModel.state == .recording { return .connecting }
        if transcriptionService.isLoading { return .loadingModel }
        if transcriptionService.isTranscribing || transcriptionQueue.isProcessing { return .processingQueue }
        if microphoneService.availableMicrophones.isEmpty { return .noMicrophone }
        return .ready
    }

    var body: some View {
        DictationDock(status: status, shortcut: shortcut, cleanupMode: $cleanupMode) {
            if viewModel.isRecording {
                viewModel.startDecoding()
            } else {
                viewModel.startRecording()
            }
        }
    }
}

enum DictationDockStatus: Equatable {
    case ready, connecting, transcribing, loadingModel, processingQueue, meeting, savingMeeting, noMicrophone
    case recording(TimeInterval)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
    var canActivate: Bool { self == .ready || isRecording }
    var title: String {
        switch self {
        case .ready: return "Ready to dictate"
        case .recording: return "Listening"
        case .connecting: return "Connecting microphone…"
        case .transcribing: return "Transcribing your dictation…"
        case .loadingModel: return "Loading speech model…"
        case .processingQueue: return "Processing audio…"
        case .meeting: return "Meeting recording in progress"
        case .savingMeeting: return "Saving meeting…"
        case .noMicrophone: return "No microphone available"
        }
    }
    func detail(shortcut: String) -> String {
        switch self {
        case .recording(let duration): return "\(TextUtil.formatDuration(duration)) · Stop when you’re finished"
        case .ready: return shortcut.isEmpty ? "Click the microphone to start" : "\(shortcut) to dictate anywhere"
        case .connecting: return "Your microphone is getting ready"
        case .transcribing, .loadingModel, .processingQueue, .savingMeeting: return "You can keep browsing your history"
        case .meeting: return "Use the meeting button above to stop"
        case .noMicrophone: return "Connect a microphone to start dictating"
        }
    }
}

struct DictationDock: View {
    let status: DictationDockStatus
    let shortcut: String
    @Binding var cleanupMode: CleanupMode
    let onRecord: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: WFSpace.lg) {
            HStack(spacing: WFSpace.md) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(status.isRecording ? Color.red : ThemePalette.iconAccent(colorScheme))
                            .frame(width: 6, height: 6)
                        Text(status.title).font(.system(size: 14, weight: .semibold))
                    }
                    Text(status.detail(shortcut: shortcut))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: WFSpace.sm)
                Button(action: onRecord) { MainRecordButton(isRecording: status.isRecording) }
                    .buttonStyle(WFPressableStyle())
                    .disabled(!status.canActivate)
                    .opacity(status.canActivate ? 1 : 0.4)
                    .help(status.isRecording ? "Stop recording" : "Start recording")
                    .accessibilityLabel(status.isRecording ? "Stop recording" : "Start recording")
                    .accessibilityHint(status.isRecording ? "Stops recording and begins transcription" : status.detail(shortcut: shortcut))
            }
            Picker("Writing mode", selection: $cleanupMode) {
                ForEach(CleanupMode.allCases) { mode in Text(mode.displayName).tag(mode) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .help(cleanupMode.description)
            .accessibilityLabel("Writing mode")
            .accessibilityHint("Changes how AI cleanup rewrites future dictations")
        }
        .padding(.horizontal, WFSpace.xl)
        .padding(.vertical, WFSpace.lg)
        .background(ThemePalette.cardBackground(colorScheme))
        .overlay(alignment: .top) {
            Rectangle().fill(ThemePalette.hairline(colorScheme)).frame(height: 1)
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var permissionsManager: PermissionsManager
    @AppStorage(RenamedAppMigration.didMigrateFromChatKey) private var didMigrateFromChat = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Permissions needed")
                .font(.title2.weight(.semibold))
                .padding()

            if didMigrateFromChat {
                Text("WorkFlow now has its own macOS identity. Your settings and History were preserved, but macOS needs these permissions once more.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("WorkFlow was renamed. Settings and History were preserved. Grant permissions once more.")
            }

            PermissionRow(
                isGranted: permissionsManager.isMicrophonePermissionGranted,
                title: "Microphone Access",
                description: "Required for audio recording",
                action: {
                    permissionsManager.requestMicrophonePermissionOrOpenSystemPreferences()
                }
            )

            PermissionRow(
                isGranted: permissionsManager.isAccessibilityPermissionGranted,
                title: "Accessibility Access",
                description: "Required to paste transcriptions into other apps",
                action: { permissionsManager.openSystemPreferences(for: .accessibility) }
            )

            Spacer()
        }
        .padding()
    }
}

struct PermissionRow: View {
    let isGranted: Bool
    let title: String
    let description: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(isGranted ? .green : .orange)

                Text(title)
                    .font(.headline)

                Spacer()

                if !isGranted {
                    Button("Grant Access") {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Grant \(title)")
                }
            }

            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .surfaceCard()
    }
}

struct RecordingRow: View {
    let recording: Recording
    let searchQuery: String
    let onDelete: () -> Void
    let onRegenerate: () -> Void
    @ObservedObject private var audioRecorder = AudioRecorder.shared

    private var isPlaying: Bool {
        audioRecorder.isPlaying && audioRecorder.currentlyPlayingURL == recording.url
    }

    var body: some View {
        RecordingCard(
            recording: recording,
            searchQuery: searchQuery,
            isPlaying: isPlaying,
            onPlay: {
                if isPlaying {
                    audioRecorder.stopPlaying()
                } else {
                    audioRecorder.playRecording(url: recording.url)
                }
            },
            onCopy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(recording.transcription, forType: .string)
            },
            onDelete: {
                if isPlaying { audioRecorder.stopPlaying() }
                onDelete()
            },
            onRegenerate: onRegenerate
        )
    }
}

/// The production card is independent of audio services, so rendering and action
/// tests can exercise the real UI without opening devices or touching history.
struct RecordingCard: View {
    let recording: Recording
    let searchQuery: String
    let isPlaying: Bool
    let onPlay: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onRegenerate: () -> Void
    @State private var showTranscription = false
    @Environment(\.colorScheme) private var colorScheme

    private var isPending: Bool {
        recording.status == .pending || recording.status == .converting || recording.status == .transcribing
    }
    
    private var isRegenerating: Bool {
        recording.isRegeneration && isPending
    }
    
    private var statusText: String {
        switch recording.status {
        case .pending:
            return "In queue..."
        case .converting:
            return "Converting..."
        case .transcribing:
            return "Transcribing..."
        case .completed:
            return ""
        case .failed:
            return "Failed"
        }
    }
    
    private var displayText: String {
        if recording.transcription.isEmpty || recording.transcription == "Starting transcription..." || recording.transcription == "In queue..." {
            return ""
        }
        return recording.transcription
    }

    private var cleanupBadgeLabel: String? {
        guard recording.status == .completed else { return nil }
        guard let source = recording.cleanupSource else { return nil }
        switch source {
        case .bedrock:
            if let modelID = recording.cleanupModelID,
               let estimate = BedrockPricing.estimateUSD(
                   modelID: modelID,
                   inputTokens: recording.cleanupInputTokens,
                   outputTokens: recording.cleanupOutputTokens
               ) {
                return "Bedrock · \(BedrockPricing.formatUSD(estimate))"
            }
            let tokenCount = (recording.cleanupInputTokens ?? 0) + (recording.cleanupOutputTokens ?? 0)
            return tokenCount > 0 ? "Bedrock · \(tokenCount) tokens" : "Bedrock"
        case .ollama:
            return "Ollama · free"
        case .openAICompatible:
            let tokenCount = (recording.cleanupInputTokens ?? 0) + (recording.cleanupOutputTokens ?? 0)
            return tokenCount > 0 ? "Custom API · \(tokenCount) tokens" : "Custom API"
        case .rawFallback:
            return "Local fallback"
        case .budgetLimited:
            return "Local · budget limit"
        case .disabled:
            return "Local only"
        }
    }

    private var cleanupBadgeHelp: String {
        switch recording.cleanupSource {
        case .bedrock:
            let input = recording.cleanupInputTokens.map(String.init) ?? "unknown"
            let output = recording.cleanupOutputTokens.map(String.init) ?? "unknown"
            return "Transcript cleaned by Bedrock (\(input) input / \(output) output tokens). Audio stayed on this Mac."
        case .ollama:
            return "Transcript cleaned locally by Ollama. No transcript or audio left this Mac."
        case .openAICompatible:
            return "Transcript cleaned by the configured OpenAI-compatible API. Audio stayed on this Mac."
        case .rawFallback:
            return "The cleanup provider was unavailable, so \(AppIdentity.productName) preserved the local transcript."
        case .budgetLimited:
            return "The monthly Bedrock limit was reached, so this transcript stayed local."
        case .disabled:
            return "This transcript was processed entirely on this Mac."
        case nil:
            return "Cleanup source was not recorded for this older transcription."
        }
    }

    private var efficiencyBadgeLabel: String? {
        guard recording.status == .completed,
              recording.tokenEstimatorID == LocalTokenEstimator.identifier,
              let mode = recording.cleanupMode,
              let sourceTokens = recording.rawTokenEstimate,
              let finalTokens = recording.finalTokenEstimate,
              sourceTokens > 0,
              finalTokens > 0 else { return nil }
        switch recording.cleanupSource {
        case .bedrock, .ollama, .openAICompatible:
            let ratio = Double(sourceTokens) / Double(finalTokens)
            return "\(mode.displayName) · \(TokenEfficiencyFormatter.ratio(ratio))"
        case .rawFallback, .budgetLimited, .disabled, nil:
            return nil
        }
    }

    private var efficiencyBadgeHelp: String {
        let source = recording.rawTokenEstimate ?? 0
        let final = recording.finalTokenEstimate ?? 0
        return "Estimated locally from the source and final text: \(source) → \(final) tokens. Provider billing tokens are reported separately."
    }

    private var cleanupBadgeColor: Color {
        switch recording.cleanupSource {
        case .bedrock, .ollama, .openAICompatible:
            return ThemePalette.iconAccent(colorScheme)
        case .rawFallback, .budgetLimited:
            return .orange
        case .disabled, nil:
            return .secondary
        }
    }

    private var recordingActions: some View {
        HStack(spacing: 2) {
            cardAction(isPlaying ? "stop.fill" : "play.fill", label: isPlaying ? "Stop recording playback" : "Play recording", tint: isPlaying ? .red : .secondary, action: onPlay)
                .disabled(isPending || recording.status == .failed)
            cardAction("doc.on.doc", label: "Copy entire transcription", action: onCopy)
                .disabled(displayText.isEmpty || recording.status == .failed)
            cardAction("arrow.clockwise", label: "Regenerate transcription", action: onRegenerate)
                .disabled(isPending)
            cardAction("trash", label: "Delete transcription", action: onDelete)
        }
        .fixedSize()
    }

    private func cardAction(_ symbol: String, label: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var badges: some View {
        if let cleanupBadgeLabel {
            Text(cleanupBadgeLabel)
                .foregroundStyle(cleanupBadgeColor)
                .help(cleanupBadgeHelp)
                .accessibilityHint(cleanupBadgeHelp)
        }
        if let efficiencyBadgeLabel {
            Text(efficiencyBadgeLabel)
                .foregroundStyle(.secondary)
                .help(efficiencyBadgeHelp)
                .accessibilityHint(efficiencyBadgeHelp)
        }
    }

    private var progressLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: recording.status == .pending ? "clock" : "waveform")
                .foregroundStyle(ThemePalette.iconAccent(colorScheme))
            Text(isRegenerating ? "Updating transcription · \(statusText)" : statusText)
            if recording.status != .pending {
                Text("\(Int(recording.progress * 100))%")
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, WFSpace.md)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: WFSpace.sm) {
                HStack(spacing: 4) {
                    Text("\(WFDateFormat.dayLabel(recording.timestamp)) · \(recording.timestamp.formatted(date: .omitted, time: .shortened))")
                    Text("·")
                    Text(TextUtil.formatDuration(recording.duration))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                recordingActions
            }
            .padding(.horizontal, WFSpace.md)
            .padding(.top, WFSpace.sm)

            if recording.mode == .meeting {
                Label(recording.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Meeting", systemImage: "person.2")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, WFSpace.md)
                    .padding(.top, WFSpace.sm)
            }

            if isPending {
                if !isRegenerating, let name = recording.sourceFileName {
                    Text(name)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, WFSpace.md)
                        .padding(.top, WFSpace.sm)
                }
                progressLabel.padding(.top, WFSpace.sm)
            }

            if recording.status == .failed {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Transcription failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    if !recording.transcription.isEmpty {
                        Text(recording.transcription).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(WFSpace.md)
            } else if !displayText.isEmpty {
                TranscriptionView(transcribedText: displayText, searchQuery: searchQuery, isExpanded: $showTranscription)
            } else if !isPending {
                Text("No speech detected")
                    .font(.body).foregroundStyle(.secondary)
                    .padding(WFSpace.md)
            }

            if cleanupBadgeLabel != nil || efficiencyBadgeLabel != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WFSpace.md) { badges }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 5) { badges }
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, WFSpace.md)
                .padding(.bottom, WFSpace.md)
            } else if isPending {
                Color.clear.frame(height: WFSpace.md)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }
}

struct TranscriptionView: View {
    let transcribedText: String
    let searchQuery: String
    @Binding var isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var highlightedAttributedString: AttributedString?
    @State private var computeTask: Task<Void, Never>?
    
    private var hasMoreLines: Bool {
        !transcribedText.isEmpty && transcribedText.count > 150
    }
    
    private var highlightedText: Text {
        guard !searchQuery.isEmpty else {
            return Text(transcribedText)
        }
        if let attributed = highlightedAttributedString {
            return Text(attributed)
        }
        return Text(transcribedText)
    }
    
    private func computeHighlighting() {
        computeTask?.cancel()
        highlightedAttributedString = nil
        
        guard !searchQuery.isEmpty else {
            highlightedAttributedString = nil
            return
        }
        
        let text = transcribedText
        let query = searchQuery
        
        computeTask = Task.detached(priority: .userInitiated) {
            var attributedString = AttributedString(text)
            let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            
            var searchStartIndex = text.startIndex
            while let range = text.range(of: query, options: searchOptions, range: searchStartIndex..<text.endIndex) {
                guard !Task.isCancelled else { return }
                if let attributedRange = Range(range, in: attributedString) {
                    attributedString[attributedRange].backgroundColor = .yellow
                    attributedString[attributedRange].foregroundColor = .black
                }
                searchStartIndex = range.upperBound
            }
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.highlightedAttributedString = attributedString
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WFSpace.sm) {
            highlightedText
                .font(.system(size: 14))
                .lineSpacing(3)
                .lineLimit(hasMoreLines && !isExpanded ? 3 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, WFSpace.md)
                .padding(.top, WFSpace.sm)

            if hasMoreLines {
                Button { isExpanded.toggle() } label: {
                    Label(isExpanded ? "Show less" : "Show full text", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(ThemePalette.linkText(colorScheme))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, WFSpace.md)
            }
        }
        .padding(.bottom, WFSpace.md)
        .onAppear {
            computeHighlighting()
        }
        .onChange(of: searchQuery) { _, _ in
            computeHighlighting()
        }
        .onChange(of: transcribedText) { _, _ in
            computeHighlighting()
        }
        .onDisappear {
            computeTask?.cancel()
        }
    }
}

struct MicrophonePickerIconView: View {
    @ObservedObject var microphoneService: MicrophoneService
    @State private var showMenu = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    
    private var builtInMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { $0.isBuiltIn }
    }
    
    private var externalMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { !$0.isBuiltIn }
    }
    
    var body: some View {
        Button(action: {
            showMenu.toggle()
        }) {
            Image(systemName: microphoneService.availableMicrophones.isEmpty ? "mic.slash" : "mic.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: WFRadius.control, style: .continuous)
                        .fill(isHovered
                              ? BrandPalette.violet.opacity(0.14)
                              : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: WFRadius.control, style: .continuous))
        }
        .buttonStyle(WFPressableStyle())
        .onHover { isHovered = $0 }
        .help(microphoneService.currentMicrophone?.displayName ?? "Select microphone")
        .accessibilityLabel("Select microphone")
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if microphoneService.availableMicrophones.isEmpty {
                    Text("No microphones available")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(builtInMicrophones) { microphone in
                        Button(action: {
                            microphoneService.selectMicrophone(microphone)
                            showMenu = false
                        }) {
                            HStack {
                                Text(microphone.displayName)
                                Spacer()
                                if let current = microphoneService.currentMicrophone,
                                   current.id == microphone.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    
                    ForEach(externalMicrophones) { microphone in
                        Button(action: {
                            microphoneService.selectMicrophone(microphone)
                            showMenu = false
                        }) {
                            HStack {
                                Text(microphone.displayName)
                                Spacer()
                                if let current = microphoneService.currentMicrophone,
                                   current.id == microphone.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minWidth: 200)
            .padding(.vertical, 8)
        }
    }
}

struct MainRecordButton: View {
    let isRecording: Bool

    var body: some View {
        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(isRecording ? Color.red : BrandPalette.violet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
