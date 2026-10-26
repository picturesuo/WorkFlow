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
    private var initialPageLimit: Int
    private var nextOffset = 0
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?

    init(pageSize: Int = 100, loader: @escaping Loader) {
        self.pageSize = pageSize
        self.initialPageLimit = pageSize
        self.loader = loader
    }

    @discardableResult
    func search(query: String) -> Task<Void, Never> {
        self.query = query
        recordings = []
        nextOffset = 0
        return refresh()
    }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        // Even a refresh of the same query supersedes every older page request.
        generation = UUID()
        loadTask?.cancel()
        isLoadingMore = false
        initialPageLimit = max(pageSize, max(recordings.count, nextOffset))
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
        let limit = offset == 0 ? initialPageLimit : pageSize

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
                let page = try await self.loader(requestQuery, limit, offset)
                guard self.generation == requestGeneration else { return }
                if offset == 0 {
                    self.recordings = page
                } else {
                    self.recordings.append(contentsOf: page)
                }
                self.nextOffset = offset + page.count
                self.canLoadMore = page.count == limit
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
    @Published var transcriptionService: TranscriptionService
    @Published var transcriptionQueue: TranscriptionQueue
    @Published var recordingStore: RecordingStore
    var cleanupPipeline = TranscriptCleanupPipeline.shared
    private let history: RecordingHistoryModel
    var recordings: [Recording] {
        get { history.recordings }
        set { history.recordings = newValue }
    }
    var isLoadingMore: Bool { history.isLoadingMore }
    var canLoadMore: Bool { history.canLoadMore }
    var historyError: String? { history.errorMessage }
    @Published private(set) var recordingStartedAt: Date?
    @Published var microphoneService = MicrophoneService.shared
    @Published var recordingError: String?
    @Published var historyDeletionError: String?
    
    private var cancellables = Set<AnyCancellable>()
    private var recorderSessionID: UUID?

    /// Nil uses the shared service. History pages always come from
    /// `recordingStore` as it was at init.
    init(
        transcriptionService: TranscriptionService? = nil,
        transcriptionQueue: TranscriptionQueue? = nil,
        recordingStore: RecordingStore? = nil
    ) {
        let recordingStore = recordingStore ?? .shared
        self.transcriptionService = transcriptionService ?? .shared
        self.transcriptionQueue = transcriptionQueue ?? .shared
        self.recordingStore = recordingStore
        history = RecordingHistoryModel { query, limit, offset in
            if query.isEmpty {
                return try await recordingStore.fetchRecordings(limit: limit, offset: offset)
            }
            return try await recordingStore.searchRecordingsAsync(query: query, limit: limit, offset: offset)
        }

        history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        recorder.$isRecording.combineLatest(recorder.$isConnecting)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let sessionID = self.recorderSessionID else { return }
                // Both flags publish in the same main-queue block. Read the
                // settled pair rather than an intermediate Combine emission.
                let owned = self.recorder.ownsRecordingSession(sessionID)
                self.updateRecorderState(
                    isRecording: owned && self.recorder.isRecording,
                    isConnecting: owned && self.recorder.isConnecting
                )
            }
            .store(in: &cancellables)
    }

    func updateRecorderState(isRecording: Bool, isConnecting: Bool) {
        guard state != .decoding else { return }
        if isRecording {
            if state != .recording { state = .recording }
            markRecordingStartedIfNeeded()
        } else if isConnecting {
            if state != .connecting { state = .connecting }
            resetRecordingStart()
        } else if state == .recording || state == .connecting {
            state = .idle
            resetRecordingStart()
        }
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
        Task {
            do {
                try await recordingStore.deleteRecordingSync(recording)
            } catch {
                historyDeletionError = "The recording could not be deleted. Your saved audio was kept. Please try again."
            }
        }
    }
    
    func deleteAllRecordings() {
        Task {
            do {
                try await recordingStore.deleteAllRecordingsSync()
            } catch {
                historyDeletionError = "History could not be deleted. Your saved audio was kept. Please try again."
            }
        }
    }

    var isRecording: Bool {
        guard let sessionID = recorderSessionID, recorder.ownsRecordingSession(sessionID) else { return false }
        return recorder.isRecording
    }
    
    func startRecording() {
        guard !MeetingSessionController.shared.isRecording else { return }
        guard microphoneService.getActiveMicrophone() != nil else { return }

        if microphoneService.isActiveMicrophoneRequiresConnection() {
            state = .connecting
            resetRecordingStart()
        } else {
            state = .recording
            recordingStartedAt = Date()
        }
        
        let sessionID = UUID()
        guard recorder.startRecording(sessionID: sessionID, completion: { [weak self] startError in
            guard let startError else { return }
            Task { @MainActor in
                guard let self, self.recorderSessionID == sessionID else { return }
                self.recorderSessionID = nil
                self.state = .idle
                self.resetRecordingStart()
                self.recordingError = startError
            }
        }) else {
            state = .idle
            resetRecordingStart()
            recordingError = "Another recording is already starting or active."
            return
        }
        recorderSessionID = sessionID
    }

    func startDecoding() {
        guard state != .decoding, let sessionID = recorderSessionID else { return }
        recorderSessionID = nil
        state = .decoding
        resetRecordingStart()
        
        IndicatorWindowManager.shared.hide()

        Task { [weak self] in
            guard let self = self else { return }
            
            if let tempURL = await self.recorder.stopRecording(sessionID: sessionID) {
                await self.finishRecording(audioAt: tempURL)
            } else {
                await MainActor.run {
                    self.state = .idle
                }
            }
        }
    }

    /// Transcribes, cleans up, and saves one recording made in this window.
    func finishRecording(audioAt tempURL: URL) async {
        print("start decoding...")
        let duration = await AudioUtil.audioDuration(url: tempURL)
        let rawText: String
        do {
            rawText = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: tempURL)
            state = .idle
            return
        } catch {
            print("Audio-file transcription failed; the audio is kept in History.")
            let saved = await recordingStore.addFailedDictation(
                audioAt: tempURL,
                error: error,
                duration: duration,
                selectedFilter: cleanupPipeline.selectedFilter(),
                cleanupRequested: cleanupPipeline.cleanupRequested(targetBundleID: nil),
                targetBundleID: nil,
                recordingStartedAt: nil,
                keepAudio: recorder.keepTemporaryRecording
            )
            recordingError = saved
                ? "WorkFlow couldn’t transcribe this recording. Its audio is saved in History, so you can select Regenerate to try again."
                : "The recording could not be transcribed or saved. Please try again."
            state = .idle
            return
        }

        do {
            let cleanup = await cleanupPipeline.finalize(rawText)
            let text = cleanup.text

            if text.isEmpty {
                try? FileManager.default.removeItem(at: tempURL)
                print("No speech detected, dictation discarded")
            } else {
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
                    cleanupMode: cleanup.cleanupMode,
                    cleanupFilterName: cleanup.customFilterName,
                    cleanupFilterInstructions: cleanup.customFilterInstructions,
                    rawTokenEstimate: cleanup.rawTokenEstimate,
                    finalTokenEstimate: cleanup.finalTokenEstimate,
                    tokenEstimatorID: cleanup.tokenEstimatorID
                )

                // A failed move must not lose the transcript: it is still
                // saved, with whatever audio is left.
                let audioURL = recorder.keepTemporaryRecording(tempURL, at: newRecording.url)
                if audioURL != newRecording.url {
                    newRecording.sourceFileURL = audioURL?.path
                }
                let source = DictationSource(
                    recordingID: recordingId,
                    recognizerText: rawText,
                    cleanup: cleanup,
                    fallbackFilter: cleanupPipeline.selectedFilter(),
                    disposition: .notInserted
                )

                do {
                    try await self.recordingStore.addRecordingSync(newRecording, source: source)
                } catch {
                    // No history row owns this audio.
                    if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
                    throw error
                }

            }
        } catch {
            self.recordingError = "The recording could not be saved to History. Please try again."
            print("Saving the recording failed.")
            try? FileManager.default.removeItem(at: tempURL)
        }

        await MainActor.run {
            self.state = .idle
        }
    }

    private func resetRecordingStart() {
        if recordingStartedAt != nil { recordingStartedAt = nil }
    }

    private func markRecordingStartedIfNeeded() {
        if recordingStartedAt == nil {
            recordingStartedAt = Date()
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel: ContentViewModel
    @StateObject private var permissionsManager: PermissionsManager
    @StateObject private var meetingController = MeetingSessionController.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSettingsPresented = false
    @State private var settingsPane = SettingsPane.dictation
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showDeleteConfirmation = false
    @State private var showMeetingNamePrompt = false
    @State private var meetingTitle = MeetingSessionController.defaultTitle()
    @State private var searchTask: Task<Void, Never>? = nil
    private var writingFilter = WritingFilterPreferences()
    @AppStorage("modifierOnlyHotkey") private var modifierOnlyHotkeyRaw = ModifierKey.fn.rawValue
    @AppStorage("modifierChordHotkey") private var modifierChordHotkeyRaw = ModifierChord.none.rawValue

    /// Nil uses the shared services and live permission checks.
    @MainActor
    init(viewModel: ContentViewModel? = nil, permissionsManager: PermissionsManager? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? ContentViewModel())
        _permissionsManager = StateObject(wrappedValue: permissionsManager ?? PermissionsManager())
    }

    private var currentShortcutDescription: String { Self.shortcutDescription() }

    /// The dictation shortcut as saved in Settings, e.g. "⌃ / fn".
    static func shortcutDescription() -> String {
        if let symbol = RecordingTriggerConfiguration().symbol {
            return symbol
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

    private var requiresInputMonitoring: Bool {
        RecordingTriggerConfiguration(
            mouseButton: MouseButton(rawValue: AppPreferences.shared.mouseButtonHotkey) ?? .none,
            chord: ModifierChord(rawValue: modifierChordHotkeyRaw) ?? .none,
            modifierKey: ModifierKey(rawValue: modifierOnlyHotkeyRaw) ?? .none,
            secondaryModifierKey: .none
        ).requiresInputMonitoring
    }

    @ViewBuilder
    private var historyList: some View {
        if viewModel.recordings.isEmpty {
            Group {
                if viewModel.isLoadingMore {
                    ProgressView("Loading history…")
                } else if let error = viewModel.historyError {
                    HistoryLoadError(message: error, onRetry: viewModel.retryLoading)
                } else {
                    HistoryEmptyState(isSearching: !debouncedSearchText.isEmpty, query: debouncedSearchText)
                }
            }
            .padding(WFSpace.xl)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(HistoryDay.group(viewModel.recordings)) { day in
                            Section {
                                ForEach(day.recordings) { recording in
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
                                    if recording.id != day.recordings.last?.id {
                                        HistoryRowSeparator()
                                    }
                                }
                            } header: {
                                HistoryDayHeader(title: day.title)
                            }
                        }

                        if viewModel.isLoadingMore {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(WFSpace.md)
                        }
                    }
                    .padding(.bottom, WFSpace.sm)
                }
                if let error = viewModel.historyError {
                    HistoryLoadError(message: error, onRetry: viewModel.retryLoading)
                        .padding(WFSpace.md)
                }
            }
        }
    }

    var body: some View {
        Group {
            if permissionsManager.hasCompletedInitialCheck,
               !permissionsManager.isMicrophonePermissionGranted
                || !permissionsManager.isAccessibilityPermissionGranted
            {
                PermissionsView(permissionsManager: permissionsManager)
            } else {
                VStack(spacing: 0) {
                    MainToolbar(
                        searchText: $searchText,
                        meetingLabel: meetingController.statusLabel,
                        isMeetingRecording: meetingController.isRecording,
                        isMeetingAvailable: meetingController.isRecording
                            || !(meetingController.isBusy || viewModel.state != .idle),
                        canDeleteAll: !(viewModel.recordings.isEmpty && debouncedSearchText.isEmpty),
                        onMeeting: {
                            if meetingController.isRecording {
                                Task { await meetingController.stop() }
                            } else {
                                meetingTitle = MeetingSessionController.defaultTitle()
                                showMeetingNamePrompt = true
                            }
                        },
                        onDeleteAll: { showDeleteConfirmation = true },
                        onSettings: { SettingsRequest.open() }
                    )
                    .onChange(of: searchText) { _, query in performSearch(query) }
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
                    WFHairline()

                    if permissionsManager.hasCompletedInitialCheck,
                       requiresInputMonitoring,
                       !permissionsManager.isInputMonitoringPermissionGranted {
                        InputMonitoringNotice(shortcut: currentShortcutDescription) {
                            permissionsManager.requestInputMonitoringPermissionOrOpenSystemPreferences()
                        }
                    }

                    historyList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ThemePalette.contentBackground(colorScheme))

                    DictationControls(
                        viewModel: viewModel,
                        transcriptionService: viewModel.transcriptionService,
                        transcriptionQueue: viewModel.transcriptionQueue,
                        microphoneService: viewModel.microphoneService,
                        meetingController: meetingController,
                        shortcut: currentShortcutDescription,
                        writingFilter: writingFilter
                    )
                }
                // The toolbar row is the title bar, beside the traffic lights.
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .frame(minWidth: 440, idealWidth: 560, minHeight: 460)
        .background(ThemePalette.chromeBackground(colorScheme))
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
            SettingsView(selection: $settingsPane)
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
        .alert(
            "Couldn’t delete recordings",
            isPresented: Binding(
                get: { viewModel.historyDeletionError != nil },
                set: { if !$0 { viewModel.historyDeletionError = nil } }
            )
        ) {
            Button("OK") { viewModel.historyDeletionError = nil }
        } message: {
            Text(viewModel.historyDeletionError ?? "Please try again.")
        }
        .modifier(OpenSettingsRequests(isPresented: $isSettingsPresented, pane: $settingsPane))
        .onDisappear { searchTask?.cancel() }
    }
}


/// One row in the title bar band: the window title, search, and the
/// window's actions, the way a unified macOS toolbar reads.
struct MainToolbar: View {
    @Binding var searchText: String
    let meetingLabel: String
    let isMeetingRecording: Bool
    let isMeetingAvailable: Bool
    let canDeleteAll: Bool
    let onMeeting: () -> Void
    let onDeleteAll: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: WFSpace.sm) {
            HStack(spacing: 6) {
                WorkFlowMark(size: 18)
                Text("History")
                    .font(.headline)
                    .lineLimit(1)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: WFSpace.sm)

            SearchField(text: $searchText, prompt: "Search History")
                .frame(minWidth: 110, idealWidth: 220, maxWidth: 240)

            HStack(spacing: 2) {
                ToolbarIconButton(
                    systemImage: isMeetingRecording ? "stop.circle.fill" : "person.2.wave.2",
                    help: meetingLabel,
                    accessibilityLabel: meetingLabel,
                    tint: isMeetingRecording ? .red : .secondary,
                    action: onMeeting
                )
                .disabled(!isMeetingAvailable)

                Menu {
                    Button("Delete All Recordings…", role: .destructive, action: onDeleteAll)
                        .disabled(!canDeleteAll)
                } label: {
                    ToolbarGlyph(systemImage: "ellipsis.circle")
                }
                .frame(width: 28, height: 28)
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .tint(.secondary)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More History actions")

                ToolbarIconButton(
                    systemImage: "gearshape",
                    help: "Settings",
                    accessibilityLabel: "Settings",
                    action: onSettings
                )
            }
        }
        .padding(.leading, WFChrome.trafficLightInset)
        .padding(.trailing, WFSpace.md)
        .frame(height: WFChrome.titleBarHeight)
    }
}

struct InputMonitoringNotice: View {
    let shortcut: String
    let onEnable: () -> Void

    var body: some View {
        HStack(spacing: WFSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Enable Input Monitoring to use \(shortcut).")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: WFSpace.sm)
            Button("Enable", action: onEnable)
                .controlSize(.small)
                .accessibilityLabel("Enable Input Monitoring")
        }
        .padding(.horizontal, WFSpace.lg)
        .padding(.vertical, WFSpace.sm)
        .background(Color.orange.opacity(0.10))
        .overlay(alignment: .bottom) { WFHairline() }
    }
}

/// Consecutive History rows from one calendar day, newest first.
struct HistoryDay: Identifiable {
    let id: String
    let title: String
    var recordings: [Recording]

    static func group(_ recordings: [Recording], calendar: Calendar = .current) -> [HistoryDay] {
        var days: [HistoryDay] = []
        var lastStart: Date?
        for recording in recordings {
            let start = calendar.startOfDay(for: recording.timestamp)
            if start == lastStart, !days.isEmpty {
                days[days.count - 1].recordings.append(recording)
            } else {
                days.append(HistoryDay(
                    id: "\(start.timeIntervalSince1970)-\(days.count)",
                    title: WFDateFormat.dayLabel(recording.timestamp),
                    recordings: [recording]
                ))
                lastStart = start
            }
        }
        return days
    }
}

struct HistoryDayHeader: View {
    let title: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HistoryRow.horizontalPadding)
            .padding(.top, WFSpace.md)
            .padding(.bottom, WFSpace.xs)
            .background(ThemePalette.contentBackground(colorScheme))
            .accessibilityAddTraits(.isHeader)
    }
}

struct HistoryRowSeparator: View {
    var body: some View {
        WFHairline().padding(.leading, HistoryRow.horizontalPadding)
    }
}

struct HistoryLoadError: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: WFSpace.sm) {
            Label("Couldn’t load history", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
            Button("Try Again", action: onRetry)
        }
        .multilineTextAlignment(.center)
    }
}

struct HistoryEmptyState: View {
    let isSearching: Bool
    var query = ""

    var body: some View {
        if isSearching {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label {
                    Text("Make room for your next thought")
                } icon: {
                    WorkFlowMark(size: 48)
                }
            } description: {
                Text("Record a dictation, or drop an audio file here.\nYour transcripts will appear in this history.")
            }
        }
    }
}

private struct DictationControls: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var transcriptionService: TranscriptionService
    @ObservedObject var transcriptionQueue: TranscriptionQueue
    @ObservedObject var microphoneService: MicrophoneService
    @ObservedObject var meetingController: MeetingSessionController
    let shortcut: String
    let writingFilter: WritingFilterPreferences

    private var status: DictationDockStatus {
        if meetingController.isSaving { return .savingMeeting }
        if meetingController.isRecording { return .meeting }
        if viewModel.state == .decoding { return .transcribing }
        // Stopping dictation must remain available even when another service becomes busy.
        if viewModel.isRecording { return .recording(0) }
        if viewModel.state == .connecting || viewModel.state == .recording { return .connecting }
        if transcriptionService.isLoading { return .loadingModel }
        if transcriptionService.isTranscribing || transcriptionQueue.isProcessing { return .processingQueue }
        if microphoneService.availableMicrophones.isEmpty { return .noMicrophone }
        return .ready
    }

    var body: some View {
        if status.isRecording, let startedAt = viewModel.recordingStartedAt {
            // Only the dock ticks. The history does not depend on elapsed time.
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                dock(status: .recording(max(0, context.date.timeIntervalSince(startedAt))))
            }
        } else {
            dock(status: status)
        }
    }

    private func dock(status: DictationDockStatus) -> some View {
        DictationDock(
            status: status,
            shortcut: shortcut,
            writingSelection: writingFilter.selectionBinding,
            customFilters: writingFilter.filters,
            writingHelp: writingFilter.selectionDescription,
            onLearn: { SettingsRequest.open(pane: .personalize) },
            microphones: microphoneService.availableMicrophones,
            currentMicrophoneID: microphoneService.currentMicrophone?.id,
            onSelectMicrophone: { microphoneService.selectMicrophone($0) }
        ) {
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
        case .ready: return shortcut.isEmpty ? "Click the microphone to start" : "Press \(shortcut) to dictate anywhere"
        case .connecting: return "Your microphone is getting ready"
        case .transcribing, .loadingModel, .processingQueue, .savingMeeting: return "You can keep browsing your history"
        case .meeting: return "Use the meeting button above to stop"
        case .noMicrophone: return "Connect a microphone to start dictating"
        }
    }
}

/// The window's command bar: how future dictations are written, what the
/// dictation is doing now, and the in-window record control. Its height
/// stays the same in every state, so History never jumps.
struct DictationDock: View {
    let status: DictationDockStatus
    let shortcut: String
    @Binding var writingSelection: CleanupFilterSelection
    var customFilters: [CustomCleanupFilter] = []
    var writingHelp = ""
    /// Opens Learn from finished writing; the dock shows no link without it.
    var onLearn: (() -> Void)?
    var microphones: [MicrophoneService.AudioDevice] = []
    var currentMicrophoneID: String?
    /// Chooses the input; the dock shows no microphone menu without it.
    var onSelectMicrophone: ((MicrophoneService.AudioDevice) -> Void)?
    let onRecord: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    static let statusHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                modeControls(showsLabel: true)
                modeControls(showsLabel: false)
            }
            HStack(spacing: WFSpace.md) {
                statusLine
                Spacer(minLength: WFSpace.sm)
                recordControls
            }
            .frame(height: Self.statusHeight)
        }
        .padding(.horizontal, WFSpace.lg)
        .padding(.vertical, WFSpace.md)
        .overlay(alignment: .top) { WFHairline() }
    }

    private func modeControls(showsLabel: Bool) -> some View {
        HStack(spacing: WFSpace.md) {
            if showsLabel {
                Text("Dictation mode")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
                writingPicker.fixedSize()
            } else {
                writingPicker.frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsLabel { Spacer(minLength: 0) }
            learnLink
        }
    }

    private var writingPicker: some View {
        WritingFilterPicker(selection: $writingSelection, customFilters: customFilters)
            .labelsHidden()
            .help(writingHelp)
            .accessibilityHint("Changes how AI cleanup rewrites future dictations")
    }

    @ViewBuilder
    private var learnLink: some View {
        if let onLearn {
            Button("Learn…", action: onLearn)
                .buttonStyle(.borderless)
                .font(.callout.weight(.medium))
                .foregroundStyle(ThemePalette.linkText(colorScheme))
                .fixedSize()
                .help("Teach a dictation mode your style from a document you finished")
                .accessibilityLabel("Learn from finished writing")
                .accessibilityHint("Opens Personalize settings")
        }
    }

    /// Title and detail on one line when they fit, stacked otherwise; either
    /// way the line keeps the bar's height.
    private var statusLine: some View {
        HStack(spacing: WFSpace.sm) {
            statusIndicator
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    statusTitle
                    statusDetail
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 1) {
                    statusTitle
                    statusDetail
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: some View {
        Text(status.title)
            .font(.headline)
            .lineLimit(1)
    }

    private var statusDetail: some View {
        Text(status.detail(shortcut: shortcut))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var recordControls: some View {
        HStack(spacing: 2) {
            if let onSelectMicrophone {
                MicrophoneMenu(
                    microphones: microphones,
                    currentID: currentMicrophoneID,
                    onSelect: onSelectMicrophone
                )
            }
            Button(action: onRecord) { MainRecordButton(isRecording: status.isRecording) }
                .buttonStyle(.borderless)
                .disabled(!status.canActivate)
                .opacity(status.canActivate ? 1 : 0.4)
                .help(status.isRecording ? "Stop recording" : "Start recording")
                .accessibilityLabel(status.isRecording ? "Stop recording" : "Start recording")
                .accessibilityHint(status.isRecording ? "Stops recording and begins transcription" : status.detail(shortcut: shortcut))
        }
    }

    /// Ready shows the brand ink, live recording is red, work in progress
    /// spins, and a missing microphone warns, so each state reads at a glance.
    private var statusIndicator: some View {
        Group {
            switch status {
            case .ready:
                Circle().fill(ThemePalette.ink(colorScheme)).frame(width: 7, height: 7)
            case .recording, .meeting:
                Circle().fill(Color.red).frame(width: 7, height: 7)
            case .connecting, .transcribing, .loadingModel, .processingQueue, .savingMeeting:
                ProgressView().controlSize(.small).scaleEffect(0.6)
            case .noMicrophone:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 12, height: 12)
    }
}

/// The input menu beside the record button, as in QuickTime's recorder.
struct MicrophoneMenu: View {
    let microphones: [MicrophoneService.AudioDevice]
    let currentID: String?
    let onSelect: (MicrophoneService.AudioDevice) -> Void

    private var currentName: String? {
        microphones.first { $0.id == currentID }?.displayName
    }

    private var selection: Binding<String> {
        Binding(
            get: { currentID ?? "" },
            set: { id in
                if let microphone = microphones.first(where: { $0.id == id }) { onSelect(microphone) }
            }
        )
    }

    var body: some View {
        Menu {
            if microphones.isEmpty {
                Text("No microphones available")
            } else {
                Picker("Microphone", selection: selection) {
                    Section {
                        ForEach(microphones.filter(\.isBuiltIn)) { Text($0.displayName).tag($0.id) }
                    }
                    Section {
                        ForEach(microphones.filter { !$0.isBuiltIn }) { Text($0.displayName).tag($0.id) }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            ToolbarGlyph(
                systemImage: microphones.isEmpty ? "mic.slash" : "chevron.down",
                size: 22,
                symbolSize: microphones.isEmpty ? 13 : 9
            )
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .fixedSize()
        .help(currentName.map { "Microphone: \($0)" } ?? "Choose a microphone")
        .accessibilityLabel("Microphone")
        .accessibilityValue(currentName ?? "None")
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

private struct TranscriptPasteboardKey: EnvironmentKey {
    static let defaultValue: NSPasteboard.Name = .general
}

extension EnvironmentValues {
    /// Where Copy Transcript writes; tests use a private pasteboard.
    var transcriptPasteboard: NSPasteboard.Name {
        get { self[TranscriptPasteboardKey.self] }
        set { self[TranscriptPasteboardKey.self] = newValue }
    }
}

struct RecordingRow: View {
    let recording: Recording
    let searchQuery: String
    let onDelete: () -> Void
    let onRegenerate: () -> Void
    private let audioRecorder = AudioRecorder.shared
    @Environment(\.transcriptPasteboard) private var pasteboardName
    @State private var isPlaying = false

    var body: some View {
        // Audio kept at its temporary path after a failed move still plays;
        // a row with no audio left offers neither playback nor Regenerate.
        let audioURL = recording.playableAudioURL
        HistoryRow(
            recording: recording,
            searchQuery: searchQuery,
            isPlaying: isPlaying,
            hasAudio: audioURL != nil,
            onPlay: {
                if isPlaying {
                    audioRecorder.stopPlaying()
                } else if let audioURL {
                    audioRecorder.playRecording(url: audioURL)
                }
            },
            onCopy: {
                let pasteboard = NSPasteboard(name: pasteboardName)
                pasteboard.clearContents()
                pasteboard.setString(recording.transcription, forType: .string)
            },
            onDelete: onDelete,
            onRegenerate: onRegenerate
        )
        .onReceive(
            audioRecorder.$isPlaying.combineLatest(audioRecorder.$currentlyPlayingURL)
                .map { playing, url in playing && url != nil && url == audioURL }
                .removeDuplicates()
        ) { isPlaying = $0 }
    }
}

enum HistoryRowAction: CaseIterable {
    case play, copy, regenerate, delete
}

/// What a History row offers and when. The row's own buttons, its actions
/// menu, its context menu, and its VoiceOver actions all read from here.
struct HistoryRowActions {
    let recording: Recording
    let hasAudio: Bool
    let isPlaying: Bool

    var isPending: Bool {
        recording.status == .pending || recording.status == .converting || recording.status == .transcribing
    }

    var hasText: Bool {
        !HistoryRow.displayText(for: recording).isEmpty
    }

    func isEnabled(_ action: HistoryRowAction) -> Bool {
        switch action {
        case .play: return isPlaying || (!isPending && recording.status != .failed && hasAudio)
        case .copy: return hasText && recording.status != .failed
        case .regenerate: return !isPending && hasAudio
        case .delete: return true
        }
    }

    func title(_ action: HistoryRowAction) -> String {
        switch action {
        case .play: return isPlaying ? "Stop Playback" : "Play Recording"
        case .copy: return "Copy Transcript"
        case .regenerate: return "Regenerate Transcript"
        case .delete: return "Delete Recording"
        }
    }

    func systemImage(_ action: HistoryRowAction) -> String {
        switch action {
        case .play: return isPlaying ? "stop.fill" : "play"
        case .copy: return "doc.on.doc"
        case .regenerate: return "arrow.clockwise"
        case .delete: return "trash"
        }
    }

    /// Shown on the row besides its actions menu: Stop while playing, then
    /// Regenerate for a failed transcription that kept its audio, else Copy
    /// once there is text to copy.
    var visible: [HistoryRowAction] {
        let primary: HistoryRowAction = recording.status == .failed && hasAudio ? .regenerate : .copy
        return (isPlaying ? [.play, primary] : [primary]).filter(isEnabled)
    }
}

/// One History entry, independent of audio services, so rendering and action
/// tests can exercise the real UI without opening devices or touching history.
struct HistoryRow: View {
    let recording: Recording
    let searchQuery: String
    let isPlaying: Bool
    var hasAudio = true
    let onPlay: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onRegenerate: () -> Void
    @State private var showTranscription = false

    static let horizontalPadding: CGFloat = 20

    private var actions: HistoryRowActions {
        HistoryRowActions(recording: recording, hasAudio: hasAudio, isPlaying: isPlaying)
    }

    private var isPending: Bool { actions.isPending }

    private var isRegenerating: Bool {
        recording.isRegeneration && isPending
    }
    
    private var statusText: String {
        switch recording.status {
        case .pending:
            return "In queue…"
        case .converting:
            return "Converting…"
        case .transcribing:
            return "Transcribing…"
        case .completed:
            return ""
        case .failed:
            return "Failed"
        }
    }

    static func displayText(for recording: Recording) -> String {
        if recording.transcription.isEmpty || recording.transcription == "Starting transcription..." || recording.transcription == "In queue..." {
            return ""
        }
        return recording.transcription
    }

    private var displayText: String { Self.displayText(for: recording) }

    var cleanupBadgeLabel: String? {
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
        case .azureOpenAI:
            let tokenCount = (recording.cleanupInputTokens ?? 0) + (recording.cleanupOutputTokens ?? 0)
            return tokenCount > 0 ? "Azure OpenAI · \(tokenCount) tokens" : "Azure OpenAI"
        case .rawFallback:
            return "Original transcript"
        case .budgetLimited:
            return "Cost stop reached"
        case .disabled:
            return "Cleanup off"
        }
    }

    var cleanupBadgeHelp: String {
        switch recording.cleanupSource {
        case .bedrock:
            let input = recording.cleanupInputTokens.map(String.init) ?? "unknown"
            let output = recording.cleanupOutputTokens.map(String.init) ?? "unknown"
            return "Transcript cleaned by Bedrock (\(input) input / \(output) output tokens). Audio stayed on this Mac."
        case .ollama:
            return "Transcript cleaned locally by Ollama. No transcript or audio left this Mac."
        case .openAICompatible:
            return "Transcript cleaned by the configured OpenAI-compatible API. Audio stayed on this Mac."
        case .azureOpenAI:
            return "Transcript cleaned by your Azure OpenAI deployment. Audio stayed on this Mac."
        case .rawFallback:
            return "AI cleanup didn’t finish, so \(AppIdentity.productName) kept the original transcript.\(hasAudio ? " Regenerate tries cleanup again." : "")"
        case .budgetLimited:
            return "This month’s estimated-cost stop was reached, so cleanup paused and \(AppIdentity.productName) kept the original transcript."
        case .disabled:
            return "AI cleanup was off, so this is the recognized text with your vocabulary applied. It never left this Mac."
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
        case .bedrock, .ollama, .openAICompatible, .azureOpenAI:
            let ratio = Double(sourceTokens) / Double(finalTokens)
            return "\(recording.cleanupFilterName ?? mode.displayName) · \(TokenEfficiencyFormatter.ratio(ratio))"
        case .rawFallback, .budgetLimited, .disabled, nil:
            return nil
        }
    }

    private var efficiencyBadgeHelp: String {
        let source = recording.rawTokenEstimate ?? 0
        let final = recording.finalTokenEstimate ?? 0
        let filter = recording.cleanupFilterName.map { name in
            "Custom filter “\(name)” based on \(recording.cleanupMode?.displayName ?? "a built-in mode"). "
        } ?? ""
        return "\(filter)Estimated locally from the source and final text: \(source) → \(final) tokens. Provider billing tokens are reported separately."
    }

    private var cleanupBadgeColor: Color {
        switch recording.cleanupSource {
        case .rawFallback, .budgetLimited:
            return .orange
        case .bedrock, .ollama, .openAICompatible, .azureOpenAI, .disabled, nil:
            return .secondary
        }
    }

    private func perform(_ action: HistoryRowAction) {
        switch action {
        case .play: onPlay()
        case .copy: onCopy()
        case .regenerate: onRegenerate()
        case .delete: onDelete()
        }
    }

    @ViewBuilder
    private var actionMenuItems: some View {
        ForEach([HistoryRowAction.play, .copy, .regenerate], id: \.self) { action in
            Button { perform(action) } label: {
                Label(actions.title(action), systemImage: actions.systemImage(action))
            }
            .disabled(!actions.isEnabled(action))
        }
        Divider()
        Button(role: .destructive) { perform(.delete) } label: {
            Label(actions.title(.delete), systemImage: actions.systemImage(.delete))
        }
    }

    private var rowActions: some View {
        HStack(spacing: 0) {
            ForEach(actions.visible, id: \.self) { action in
                Button { perform(action) } label: {
                    ToolbarGlyph(
                        systemImage: actions.systemImage(action),
                        tint: action == .play ? .red : .secondary,
                        size: 24,
                        symbolSize: 12
                    )
                }
                .buttonStyle(.borderless)
                .disabled(!actions.isEnabled(action))
                .help(actions.title(action))
                .accessibilityLabel(actions.title(action))
            }
            Menu { actionMenuItems } label: {
                ToolbarGlyph(systemImage: "ellipsis", size: 24, symbolSize: 12)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions")
        }
        .fixedSize()
    }

    @ViewBuilder
    private var cleanupBadge: some View {
        if let cleanupBadgeLabel {
            Group {
                if recording.cleanupSource == .rawFallback || recording.cleanupSource == .budgetLimited {
                    Label(cleanupBadgeLabel, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(CompactLabelStyle())
                } else {
                    Text(cleanupBadgeLabel)
                }
            }
            .foregroundStyle(cleanupBadgeColor)
            .help(cleanupBadgeHelp)
            .accessibilityHint(cleanupBadgeHelp)
        }
    }

    @ViewBuilder
    private var efficiencyBadge: some View {
        if let efficiencyBadgeLabel {
            Text(efficiencyBadgeLabel)
                .help(efficiencyBadgeHelp)
                .accessibilityHint(efficiencyBadgeHelp)
        }
    }

    private var hasBadges: Bool { cleanupBadgeLabel != nil || efficiencyBadgeLabel != nil }

    private var timeLabel: some View {
        Text("\(recording.timestamp.formatted(date: .omitted, time: .shortened)) · \(TextUtil.formatDuration(recording.duration))")
    }

    private var separatorDot: some View {
        Text("·").accessibilityHidden(true)
    }

    /// Time, length, and how the text was produced, on one line when it fits.
    private var metadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                timeLabel
                if cleanupBadgeLabel != nil { separatorDot; cleanupBadge }
                if efficiencyBadgeLabel != nil { separatorDot; efficiencyBadge }
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                timeLabel
                if hasBadges {
                    HStack(spacing: 5) {
                        cleanupBadge
                        if cleanupBadgeLabel != nil && efficiencyBadgeLabel != nil { separatorDot }
                        efficiencyBadge
                    }
                    .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                timeLabel
                cleanupBadge
                efficiencyBadge
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var progressLabel: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
            Text(isRegenerating ? "Updating transcription · \(statusText)" : statusText)
            if recording.status != .pending {
                Text("\(Int(recording.progress * 100))%")
                    .monospacedDigit()
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WFSpace.xs) {
            metadata
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room for the row's buttons and its actions menu.
                .padding(.trailing, CGFloat(actions.visible.count) * 24 + 40)

            if recording.mode == .meeting {
                Label(recording.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Meeting", systemImage: "person.2")
                    .labelStyle(CompactLabelStyle(spacing: 5, iconScale: .medium))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isPending {
                if !isRegenerating, let name = recording.sourceFileName {
                    Text(name)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                progressLabel
            }

            if recording.status == .failed {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Transcription failed", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(CompactLabelStyle(spacing: 4))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.red)
                    if !recording.transcription.isEmpty {
                        Text(recording.transcription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if !displayText.isEmpty {
                TranscriptionView(transcribedText: displayText, searchQuery: searchQuery, isExpanded: $showTranscription)
            } else if !isPending {
                Text("No speech detected")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            rowActions
                .padding(.top, 5)
                .padding(.trailing, WFSpace.md)
        }
        .contentShape(Rectangle())
        .contextMenu { actionMenuItems }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            ForEach(HistoryRowAction.allCases.filter { actions.isEnabled($0) }, id: \.self) { action in
                Button(actions.title(action)) { perform(action) }
            }
        }
    }
}

/// An icon tucked against its words, for metadata and inline status.
private struct CompactLabelStyle: LabelStyle {
    var spacing: CGFloat = 3
    var iconScale: Image.Scale = .small

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon.imageScale(iconScale)
            configuration.title
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
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0

    static let collapsedLineLimit = 4

    /// Offer the toggle only when the collapsed text actually hides lines.
    private var isTruncated: Bool {
        fullHeight > collapsedHeight + 1
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
            
            await MainActor.run { [attributedString] in
                guard !Task.isCancelled else { return }
                self.highlightedAttributedString = attributedString
            }
        }
    }

    private func styled(_ text: Text) -> some View {
        text
            .font(.body)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WFSpace.xs) {
            styled(highlightedText)
                .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .background(alignment: .top) {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { collapsedHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, height in collapsedHeight = height }
                    }
                }
                .background(alignment: .top) {
                    // The whole text, unclipped and invisible, to measure against.
                    styled(Text(transcribedText))
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .background(GeometryReader { proxy in
                            Color.clear
                                .onAppear { fullHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, height in fullHeight = height }
                        })
                        .accessibilityHidden(true)
                }

            if isExpanded || isTruncated {
                Button { isExpanded.toggle() } label: {
                    Label(isExpanded ? "Show less" : "Show full text", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .labelStyle(CompactLabelStyle())
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ThemePalette.linkText(colorScheme))
                }
                .buttonStyle(.borderless)
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

/// Ink disc with an inverse glyph, like the mark itself; red while recording.
struct MainRecordButton: View {
    let isRecording: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isRecording ? Color.white : ThemePalette.onInk(colorScheme))
            .frame(width: 30, height: 30)
            .background(isRecording ? Color.red : ThemePalette.ink(colorScheme), in: Circle())
            .contentShape(Circle())
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
