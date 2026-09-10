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
class ContentViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var recorder: AudioRecorder = .shared
    @Published var transcriptionService = TranscriptionService.shared
    @Published var transcriptionQueue = TranscriptionQueue.shared
    @Published var recordingStore = RecordingStore.shared
    @Published var recordings: [Recording] = []
    @Published var isLoadingMore = false
    @Published var canLoadMore = true
    @Published var recordingDuration: TimeInterval = 0
    @Published var microphoneService = MicrophoneService.shared
    @Published var shouldClearSearch = false
    @Published var recordingError: String?
    
    private var currentPage = 0
    private let pageSize = 100
    private var currentSearchQuery = ""
    private var blinkTimer: Timer?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self else { return }
                if isConnecting && self.state != .decoding {
                    self.state = .connecting
                    self.stopBlinking()
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
                    self.startBlinking()
                    self.startDurationTimerIfNeeded()
                } else if !isRecording && self.state == .recording {
                    self.state = .idle
                    self.stopBlinking()
                    self.stopDurationTimer()
                    self.recordingDuration = 0
                }
            }
            .store(in: &cancellables)
    }
    
    func loadInitialData() {
        currentSearchQuery = ""
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadMore()
    }

    func loadMore() {
        guard !isLoadingMore && canLoadMore else { return }
        isLoadingMore = true
        
        // Capture current state for async task
        let page = currentPage
        let limit = pageSize
        let query = currentSearchQuery
        let offset = page * limit
        
        
        Task {
            let newRecordings: [Recording]
            if query.isEmpty {
                newRecordings = try await recordingStore.fetchRecordings(limit: limit, offset: offset)
            } else {
                newRecordings = await recordingStore.searchRecordingsAsync(query: query, limit: limit, offset: offset)
            }
            
            
            await MainActor.run {
                defer {
                    self.isLoadingMore = false
                }
                
                // Ensure we are still consistent with the request (basic check)
                guard self.currentSearchQuery == query else { 
                    return 
                }
                
                if page == 0 {
                    self.recordings = newRecordings
                } else {
                    self.recordings.append(contentsOf: newRecordings)
                }
                
                if newRecordings.count < limit {
                    self.canLoadMore = false
                } else {
                    self.currentPage += 1
                }
            }
        }
    }
    
    func search(query: String) {
        currentSearchQuery = query
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadMore()
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
            stopBlinking()
            stopDurationTimer()
            recordingDuration = 0
        } else {
            state = .recording
            startBlinking()
            recordingStartTime = Date()
            recordingDuration = 0
            startDurationTimerIfNeeded()
        }
        
        guard recorder.startRecording(completion: { [weak self] startError in
            guard let startError else { return }
            Task { @MainActor in
                guard let self else { return }
                self.state = .idle
                self.stopBlinking()
                self.stopDurationTimer()
                self.recordingDuration = 0
                self.recordingError = startError
            }
        }) else {
            state = .idle
            stopBlinking()
            stopDurationTimer()
            recordingDuration = 0
            return
        }
    }

    func startDecoding() {
        state = .decoding
        stopBlinking()
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
                        let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                        let recordingId = UUID()
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

                        await MainActor.run {
                            self.recordingStore.addRecording(newRecording)
                            
                            if !self.currentSearchQuery.isEmpty {
                                self.shouldClearSearch = true
                                self.currentSearchQuery = ""
                            }
                            self.recordings.insert(newRecording, at: 0)
                        }

                    }
                } catch {
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

    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.isBlinking.toggle()
            }
        }
        RunLoop.main.add(blinkTimer!, forMode: .common)
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
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

    private var headerStatusText: String? {
        if viewModel.isRecording {
            return "Listening · \(TextUtil.formatDuration(viewModel.recordingDuration))"
        }
        if viewModel.state == .decoding {
            return "Transcribing…"
        }
        if viewModel.state == .connecting {
            return "Connecting…"
        }
        if meetingController.isRecording {
            return "Meeting recording"
        }
        return nil
    }

    private var dockCaptionText: String {
        if viewModel.isRecording {
            return "Tap to stop · \(TextUtil.formatDuration(viewModel.recordingDuration))"
        }
        if viewModel.state == .decoding {
            return "Transcribing…"
        }
        if viewModel.state == .connecting {
            return "Preparing…"
        }
        if !currentShortcutDescription.isEmpty {
            return "\(currentShortcutDescription) to dictate anywhere"
        }
        return "Tap to start dictating"
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
                    // Header: brand, live status, and window controls.
                    HStack(spacing: WFSpace.sm) {
                        Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(ThemePalette.brandGradient)

                        Text(AppIdentity.productName)
                            .font(.title3.weight(.semibold))

                        if let headerStatusText {
                            Text(headerStatusText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .lineLimit(1)
                        }

                        Spacer(minLength: WFSpace.sm)

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

                            MicrophonePickerIconView(microphoneService: viewModel.microphoneService)

                            if !viewModel.recordings.isEmpty {
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
                                    Text("Are you sure you want to delete all recordings? This action cannot be undone.")
                                }
                                .interactiveDismissDisabled()
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
                    .padding(.horizontal, WFSpace.lg)
                    .padding(.top, 28)

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

                    // Search bar
                    HStack(spacing: WFSpace.sm) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)

                        TextField("Search in transcriptions", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())
                            .onChange(of: searchText) { _, newValue in
                                performSearch(newValue)
                            }

                        if !searchText.isEmpty {
                            Button(action: {
                                searchText = ""
                                debouncedSearchText = ""
                                searchTask?.cancel()
                                viewModel.search(query: "")
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .imageScale(.medium)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(height: 32)
                    .background(ThemePalette.panelSurface(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: WFRadius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: WFRadius.control, style: .continuous)
                            .stroke(ThemePalette.panelBorder(colorScheme), lineWidth: 1)
                    )
                    .padding(.horizontal, WFSpace.lg)
                    .padding(.top, WFSpace.md)

                    ScrollView(showsIndicators: false) {
                        if viewModel.recordings.isEmpty {
                            VStack(spacing: WFSpace.md) {
                                if !debouncedSearchText.isEmpty {
                                    // Show "no results" for search
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 44))
                                        .foregroundStyle(ThemePalette.brandGradient)

                                    Text("No results found")
                                        .font(.headline)

                                    Text("Try different search terms")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)
                                } else {
                                    // Show "start recording" tip
                                    Image(systemName: "waveform.circle")
                                        .font(.system(size: 44))
                                        .foregroundStyle(ThemePalette.brandGradient)

                                    Text("No dictations yet")
                                        .font(.headline)

                                    if !currentShortcutDescription.isEmpty {
                                        HStack(spacing: WFSpace.xs) {
                                            Text("Press")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                            KeyCapView(text: currentShortcutDescription)
                                            Text("anywhere to dictate into any app.")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal)
                                    } else {
                                        Text("Press the record button below to get started.")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal)
                                    }

                                    HStack(spacing: WFSpace.xs) {
                                        Image(systemName: "arrow.down.doc")
                                        Text("Drop an audio file here to transcribe it.")
                                    }
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                        } else {
                            LazyVStack(spacing: WFSpace.sm) {
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
                            .padding(.horizontal, WFSpace.lg)
                            .padding(.top, 16)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: viewModel.recordings.count)
                    .animation(.easeInOut(duration: 0.2), value: debouncedSearchText.isEmpty)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        ThemePalette.windowBackground(colorScheme).opacity(1),
                                        ThemePalette.windowBackground(colorScheme).opacity(0)
                                    ]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 16)
                    }

                    VStack(spacing: WFSpace.md) {
                        Button(action: {
                            if viewModel.isRecording {
                                viewModel.startDecoding()
                            } else {
                                viewModel.startRecording()
                            }
                        }) {
                            if viewModel.state == .decoding || viewModel.state == .connecting {
                                ProgressView()
                                    .scaleEffect(1.0)
                                    .frame(width: 56, height: 56)
                                    .contentTransition(.symbolEffect(.replace))
                            } else {
                                MainRecordButton(isRecording: viewModel.isRecording)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            viewModel.state == .decoding ? "Transcribing" :
                                viewModel.state == .connecting ? "Preparing transcription" :
                                viewModel.isRecording ? "Stop recording" : "Start recording"
                        )
                        .accessibilityHint(
                            viewModel.isRecording
                                ? "Stops recording and begins transcription"
                                : "Starts a new dictation"
                        )
                        .disabled(viewModel.transcriptionService.isLoading || viewModel.transcriptionService.isTranscribing || viewModel.transcriptionQueue.isProcessing || viewModel.state == .decoding || viewModel.microphoneService.availableMicrophones.isEmpty || meetingController.isBusy)
                        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.isRecording)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isRecording)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.state)

                        Text(dockCaptionText)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .contentTransition(.numericText())
                            .multilineTextAlignment(.center)

                        VStack(alignment: .leading, spacing: 5) {
                            Picker("Writing mode", selection: cleanupModeBinding) {
                                ForEach(CleanupMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityHint("Changes how AI cleanup rewrites future dictations")

                            Text(selectedCleanupMode.description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(WFSpace.lg)
                    .background(ThemePalette.panelSurface(colorScheme))
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(ThemePalette.hairline(colorScheme))
                            .frame(height: 1)
                    }
                }
            }
        }
        .frame(minWidth: 400, idealWidth: 400)
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
            viewModel.loadInitialData()
        }
        .overlay {
            let isPermissionsGranted = permissionsManager.isMicrophonePermissionGranted
                && permissionsManager.isAccessibilityPermissionGranted

            if viewModel.transcriptionService.isLoading && isPermissionsGranted {
                ZStack {
                    Rectangle()
                        .fill(.regularMaterial)
                    VStack(spacing: WFSpace.md) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(BrandPalette.violet)
                        Text("Loading speech model…")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("This only takes a moment the first time.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .ignoresSafeArea()
            }
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
        .onChange(of: viewModel.shouldClearSearch) { _, shouldClear in
            if shouldClear {
                searchText = ""
                debouncedSearchText = ""
                searchTask?.cancel()
                viewModel.shouldClearSearch = false
            }
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
    @StateObject private var audioRecorder = AudioRecorder.shared
    @State private var showTranscription = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var isPlaying: Bool {
        audioRecorder.isPlaying && audioRecorder.currentlyPlayingURL == recording.url
    }
    
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recording.mode == .meeting, let title = recording.title, !title.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "person.2.wave.2.fill")
                        .foregroundColor(ThemePalette.iconAccent(colorScheme))
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text("Meeting")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            if isPending && !isRegenerating {
                VStack(alignment: .leading, spacing: 4) {
                    if let sourceFileName = recording.sourceFileName {
                        Text(sourceFileName)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    HStack(spacing: 6) {
                        if recording.status == .pending {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                           
                            ZStack {
                                Circle()
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                                
                                Circle()
                                    .trim(from: 0, to: CGFloat(recording.progress))
                                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.1), value: recording.progress)
                            }
                            .frame(width: 16, height: 16)

                            Text("\(Int(recording.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .contentTransition(.numericText())
                                .animation(.linear(duration: 0.1), value: recording.progress)
                        }
                        
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            
            if recording.status == .failed {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                        Text("Transcription failed")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    if !recording.transcription.isEmpty {
                        Text(recording.transcription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, isPending && !isRegenerating ? 4 : 8)
            } else if !displayText.isEmpty {
                ZStack(alignment: .topLeading) {
                    TranscriptionView(
                        transcribedText: displayText,
                        searchQuery: searchQuery,
                        isExpanded: $showTranscription
                    )
                    
                    if isRegenerating {
                        ShimmerOverlay()
                            .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, isPending && !isRegenerating ? 4 : 8)
            } else if !isPending {
                Text("No speech detected")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.timestamp, style: .date)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 4) {
                        Text(recording.timestamp, style: .time)
                        Text("·")
                        Text(TextUtil.formatDuration(recording.duration))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                if let cleanupBadgeLabel {
                    Text(cleanupBadgeLabel)
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundColor(cleanupBadgeColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(cleanupBadgeColor.opacity(0.1))
                        .clipShape(Capsule())
                        .lineLimit(1)
                        .help(cleanupBadgeHelp)
                }

                if let efficiencyBadgeLabel {
                    Text(efficiencyBadgeLabel)
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundColor(BrandPalette.lavender)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(BrandPalette.violet.opacity(0.14))
                        .clipShape(Capsule())
                        .lineLimit(1)
                        .help(efficiencyBadgeHelp)
                        .accessibilityLabel(efficiencyBadgeLabel)
                        .accessibilityHint(efficiencyBadgeHelp)
                }
                
                if isRegenerating {
                    Spacer()
                        .frame(width: 2)
                    HStack(spacing: 6) {
                        if recording.status == .pending {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ZStack {
                                Circle()
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                                
                                Circle()
                                    .trim(from: 0, to: CGFloat(recording.progress))
                                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.1), value: recording.progress)
                            }
                            .frame(width: 16, height: 16)

                            Text("\(Int(recording.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .contentTransition(.numericText())
                                .animation(.linear(duration: 0.1), value: recording.progress)
                        }
                        
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .transition(.opacity)
                
                }

                Spacer()

                HStack(spacing: 16) {
                    if !isPending && recording.status != .failed && (isHovered || isPlaying) {
                        Button(action: {
                            if isPlaying {
                                audioRecorder.stopPlaying()
                            } else {
                                audioRecorder.playRecording(url: recording.url)
                            }
                        }) {
                            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(isPlaying ? .red : ThemePalette.iconAccent(colorScheme))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPlaying ? "Stop recording playback" : "Play recording")
                        .transition(.opacity)

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                recording.transcription, forType: .string
                            )
                        }) {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy entire text")
                        .accessibilityLabel("Copy entire transcription")
                        .transition(.opacity)
                    }

                    if (recording.status == .completed || recording.status == .failed) && isHovered {
                        Button(action: {
                            onRegenerate()
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Regenerate transcription")
                        .accessibilityLabel("Regenerate transcription")
                        .transition(.opacity)
                    }

                    if isHovered || isPlaying || (isPending && !isRegenerating) || recording.status == .failed {
                        Button(action: {
                            if isPlaying {
                                audioRecorder.stopPlaying()
                            }
                            onDelete()
                        }) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete transcription")
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isHovered)
                .animation(.easeInOut(duration: 0.2), value: isPlaying)
                .animation(.easeInOut(duration: 0.2), value: isRegenerating)
            }
            .animation(.easeInOut(duration: 0.2), value: isRegenerating)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(ThemePalette.cardBackground(colorScheme))
        }
        .background(ThemePalette.cardBackground(colorScheme))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ThemePalette.cardBorder(colorScheme), lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .padding(.vertical, 4)
    }
}

struct ShimmerOverlay: View {
    @State private var phase: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.clear,
                                    Color.white.opacity(0.4),
                                    Color.clear
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .offset(x: -geometry.size.width + (phase * geometry.size.width * 2))
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onAppear {
            withAnimation(
                .linear(duration: 1.2)
                .repeatForever(autoreverses: false)
            ) {
                phase = 1
            }
        }
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
                self.highlightedAttributedString = attributedString
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if isExpanded {
                    ScrollView {
                        highlightedText
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture()
                            .onEnded {
                                if hasMoreLines {
                                    isExpanded.toggle()
                                }
                            }
                    )
                } else {
                    if hasMoreLines {
                        Button(action: { isExpanded.toggle() }) {
                            highlightedText
                                .font(.body)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        highlightedText
                            .font(.body)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(8)

            if hasMoreLines {
                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Show less" : "Show more")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .foregroundColor(ThemePalette.linkText(colorScheme))
                    .font(.footnote)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
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
                .font(.title3)
                .foregroundColor(.secondary)
                .frame(width: 32, height: 32)
                .background(ThemePalette.panelSurface(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ThemePalette.panelBorder(colorScheme), lineWidth: 1)
                )
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .help(microphoneService.currentMicrophone?.displayName ?? "Select microphone")
        .popover(isPresented: $showMenu, arrowEdge: .top) {
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var buttonColor: Color {
        ThemePalette.recordButtonBase(colorScheme)
    }

    private var recordingGradient: LinearGradient {
        LinearGradient(
            colors: [Color.red.opacity(0.85), Color.red],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        Circle()
            .fill(isRecording ? AnyShapeStyle(recordingGradient) : AnyShapeStyle(ThemePalette.brandGradient))
            .frame(width: 56, height: 56)
            .shadow(
                color: isRecording ? .red.opacity(0.5) : buttonColor.opacity(0.3),
                radius: 12,
                x: 0,
                y: 0
            )
            .overlay {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                isRecording ? .red.opacity(0.6) : buttonColor.opacity(0.6),
                                isRecording ? .red.opacity(0.3) : buttonColor.opacity(0.3)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .overlay {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .background {
                if isRecording && !reduceMotion {
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 2)
                        .frame(width: 56, height: 56)
                        .scaleEffect(pulse ? 1.35 : 1.0)
                        .opacity(pulse ? 0 : 1)
                        .onAppear {
                            pulse = false
                            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                                pulse = true
                            }
                        }
                        .onDisappear { pulse = false }
                }
            }
            .scaleEffect(isRecording ? 0.9 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRecording)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
