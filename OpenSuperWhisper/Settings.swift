import AppKit
import Combine
import Foundation
import SwiftUI
import FluidAudio

class SettingsViewModel: ObservableObject {
    @Published var selectedEngine: String {
        didSet {
            AppPreferences.shared.selectedEngine = selectedEngine
            if selectedEngine == "whisper" {
                loadAvailableModels()
            } else {
                initializeFluidAudioModels()
            }
            resetLanguageIfUnsupported()
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
    }
    
    @Published var fluidAudioModelVersion: String {
        didSet {
            AppPreferences.shared.fluidAudioModelVersion = fluidAudioModelVersion
            if selectedEngine == "fluidaudio" {
                Task { @MainActor in
                    TranscriptionService.shared.reloadEngine()
                }
            }
            initializeFluidAudioModels()
            resetLanguageIfUnsupported()
        }
    }
    
    var supportedLanguages: [String] {
        LanguageUtil.supportedLanguages(engine: selectedEngine, fluidAudioModelVersion: fluidAudioModelVersion)
    }
    
    private func resetLanguageIfUnsupported() {
        if !supportedLanguages.contains(selectedLanguage) {
            selectedLanguage = LanguageUtil.fallbackLanguage(engine: selectedEngine)
        } else {
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
    }
    
    @Published var selectedModelURL: URL? {
        didSet {
            if let url = selectedModelURL {
                AppPreferences.shared.selectedWhisperModelPath = url.path
            }
        }
    }

    /// User-initiated model selection. Persists the model and, if the model declares a
    /// preferred language (e.g. the ivrit.ai Hebrew model), switches the language to it.
    /// Do not call from init/restore — only in response to an explicit user action.
    func selectModel(_ url: URL) {
        selectedModelURL = url
        if let lang = SettingsDownloadableModels.preferredLanguage(forFilename: url.lastPathComponent),
           selectedLanguage != lang {
            selectedLanguage = lang
        }
    }

    @Published var availableModels: [URL] = []
    
    @Published var downloadableModels: [SettingsDownloadableModel] = []
    @Published var downloadableFluidAudioModels: [SettingsFluidAudioModel] = []
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?
    private var downloadTask: Task<Void, Error>?
    
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
    }

    @Published var suppressBlankAudio: Bool {
        didSet {
            AppPreferences.shared.suppressBlankAudio = suppressBlankAudio
        }
    }

    @Published var showTimestamps: Bool {
        didSet {
            AppPreferences.shared.showTimestamps = showTimestamps
        }
    }
    
    @Published var temperature: Double {
        didSet {
            AppPreferences.shared.temperature = temperature
        }
    }

    @Published var noSpeechThreshold: Double {
        didSet {
            AppPreferences.shared.noSpeechThreshold = noSpeechThreshold
        }
    }

    @Published var initialPrompt: String {
        didSet {
            AppPreferences.shared.initialPrompt = initialPrompt
        }
    }

    @Published var useBeamSearch: Bool {
        didSet {
            AppPreferences.shared.useBeamSearch = useBeamSearch
        }
    }

    @Published var beamSize: Int {
        didSet {
            AppPreferences.shared.beamSize = beamSize
        }
    }

    @Published var playSoundOnRecordStart: Bool {
        didSet {
            AppPreferences.shared.playSoundOnRecordStart = playSoundOnRecordStart
        }
    }
    
    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }
    
    @Published var modifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.modifierOnlyHotkey = modifierOnlyHotkey.rawValue
            if modifierOnlyHotkey != .none {
                AppPreferences.shared.lastModifierOnlyHotkey = modifierOnlyHotkey.rawValue
            }
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var secondaryModifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.secondaryModifierOnlyHotkey = secondaryModifierOnlyHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var mouseButtonHotkey: MouseButton {
        didSet {
            AppPreferences.shared.mouseButtonHotkey = mouseButtonHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var modifierChordHotkey: ModifierChord {
        didSet {
            AppPreferences.shared.modifierChordHotkey = modifierChordHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }
    
    @Published var holdToRecord: Bool {
        didSet {
            AppPreferences.shared.holdToRecord = holdToRecord
        }
    }

    @Published var doublePressToTrigger: Bool {
        didSet {
            AppPreferences.shared.doublePressToTrigger = doublePressToTrigger
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }
    
    @Published var escCancelWithoutConfirmation: Bool {
        didSet {
            AppPreferences.shared.escCancelWithoutConfirmation = escCancelWithoutConfirmation
        }
    }

    @Published var ignoreEscWhileRecording: Bool {
        didSet {
            AppPreferences.shared.ignoreEscWhileRecording = ignoreEscWhileRecording
        }
    }

    @Published var startHiddenInMenuBar: Bool {
        didSet {
            AppPreferences.shared.startHiddenInMenuBar = startHiddenInMenuBar
        }
    }
    
    @Published var addSpaceAfterSentence: Bool {
        didSet {
            AppPreferences.shared.addSpaceAfterSentence = addSpaceAfterSentence
        }
    }

    @Published var autoCopyToClipboard: Bool {
        didSet {
            AppPreferences.shared.autoCopyToClipboard = autoCopyToClipboard
        }
    }

    @Published var autoPasteTranscription: Bool {
        didSet {
            AppPreferences.shared.autoPasteTranscription = autoPasteTranscription
        }
    }

    @Published var bedrockCleanupEnabled: Bool {
        didSet {
            AppPreferences.shared.bedrockCleanupEnabled = bedrockCleanupEnabled
        }
    }

    @Published var bedrockRegion: String {
        didSet {
            AppPreferences.shared.bedrockRegion = bedrockRegion
        }
    }

    @Published var bedrockModelID: String {
        didSet {
            AppPreferences.shared.bedrockModelID = bedrockModelID
        }
    }

    @Published var bedrockTimeoutSeconds: Double {
        didSet {
            AppPreferences.shared.bedrockTimeoutSeconds = bedrockTimeoutSeconds
        }
    }

    @Published var bedrockMonthlyBudgetEnabled: Bool {
        didSet {
            AppPreferences.shared.bedrockMonthlyBudgetEnabled = bedrockMonthlyBudgetEnabled
        }
    }

    @Published var bedrockMonthlyBudgetUSD: Double {
        didSet {
            // Reassigning a @Published value re-enters didSet, so only an
            // out-of-range value is replaced; the nested call then saves it.
            let clamped = max(0.05, bedrockMonthlyBudgetUSD)
            guard clamped == bedrockMonthlyBudgetUSD else {
                bedrockMonthlyBudgetUSD = clamped
                return
            }
            AppPreferences.shared.bedrockMonthlyBudgetUSD = clamped
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            AppPreferences.shared.launchAtLogin = launchAtLogin
            LaunchAtLoginManager.reconcile(enabled: launchAtLogin)
        }
    }

    @Published var bedrockAPIKeyInput = ""
    @Published private(set) var hasBedrockAPIKey = false
    /// Whether the OpenAI-compatible and Azure keys are stored; the provider
    /// pane updates these after it saves or removes one.
    @Published var hasCompatibleAPIKey: Bool
    @Published var hasAzureAPIKey: Bool
    @Published private(set) var bedrockStatus = ""
    @Published private(set) var isTestingBedrock = false
    @Published private(set) var bedrockUsageSummary = BedrockUsageSummary()
    @Published private(set) var tokenEfficiencySummary = TokenEfficiencySummary.empty
    @Published private(set) var bedrockLastErrorMessage: String?
    @Published private(set) var bedrockLastErrorDate: Date?

    init(credentials: StoredCredentialStatus = .keychain) {
        let prefs = AppPreferences.shared
        self.selectedEngine = prefs.selectedEngine
        self.fluidAudioModelVersion = prefs.fluidAudioModelVersion
        self.selectedLanguage = prefs.whisperLanguage
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.modifierOnlyHotkey = ModifierKey(rawValue: prefs.modifierOnlyHotkey) ?? .none
        self.secondaryModifierOnlyHotkey = ModifierKey(rawValue: prefs.secondaryModifierOnlyHotkey) ?? .none
        self.mouseButtonHotkey = MouseButton(rawValue: prefs.mouseButtonHotkey) ?? .none
        self.modifierChordHotkey = ModifierChord(rawValue: prefs.modifierChordHotkey) ?? .none
        self.holdToRecord = prefs.holdToRecord
        self.doublePressToTrigger = prefs.doublePressToTrigger
        self.escCancelWithoutConfirmation = prefs.escCancelWithoutConfirmation
        self.ignoreEscWhileRecording = prefs.ignoreEscWhileRecording
        self.startHiddenInMenuBar = prefs.startHiddenInMenuBar
        self.addSpaceAfterSentence = prefs.addSpaceAfterSentence
        self.autoCopyToClipboard = prefs.autoCopyToClipboard
        self.autoPasteTranscription = prefs.autoPasteTranscription
        self.bedrockCleanupEnabled = prefs.bedrockCleanupEnabled
        self.bedrockRegion = prefs.bedrockRegion
        self.bedrockModelID = prefs.bedrockModelID
        self.bedrockTimeoutSeconds = prefs.bedrockTimeoutSeconds
        self.bedrockMonthlyBudgetEnabled = prefs.bedrockMonthlyBudgetEnabled
        self.bedrockMonthlyBudgetUSD = prefs.bedrockMonthlyBudgetUSD
        self.launchAtLogin = prefs.launchAtLogin
        self.bedrockLastErrorMessage = prefs.bedrockLastErrorMessage
        self.bedrockLastErrorDate = prefs.bedrockLastErrorDate
        self.hasCompatibleAPIKey = credentials.cleanup(.openAICompatible)
        self.hasAzureAPIKey = credentials.cleanup(.azureOpenAI)

        do {
            self.hasBedrockAPIKey = try credentials.bedrock()
        } catch {
            self.bedrockStatus = error.localizedDescription
        }

        if let savedPath = prefs.selectedWhisperModelPath ?? prefs.selectedModelPath {
            self.selectedModelURL = URL(fileURLWithPath: savedPath)
        }
        loadAvailableModels()
        initializeDownloadableModels()
        initializeFluidAudioModels()
        
        if !supportedLanguages.contains(selectedLanguage) {
            let fallback = LanguageUtil.fallbackLanguage(engine: selectedEngine)
            selectedLanguage = fallback
            AppPreferences.shared.whisperLanguage = fallback
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
    }

    @MainActor
    func saveAndTestBedrock() async {
        isTestingBedrock = true
        defer { isTestingBedrock = false }

        do {
            let enteredKey = bedrockAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let storedKey = try BedrockCredentialStore.loadAPIKey()
            guard let token = enteredKey.isEmpty ? storedKey : enteredKey, !token.isEmpty else {
                hasBedrockAPIKey = false
                bedrockStatus = "Enter a Bedrock API key first."
                return
            }

            let result = try await BedrockCleanupService.shared.clean(
                transcript: "Um, this is a \(AppIdentity.productName) connection test.",
                apiKey: token,
                configuration: BedrockCleanupConfiguration(
                    region: bedrockRegion,
                    modelID: bedrockModelID,
                    timeout: bedrockTimeoutSeconds
                )
            )
            if !enteredKey.isEmpty {
                try BedrockCredentialStore.saveAPIKey(enteredKey)
                bedrockAPIKeyInput = ""
            }
            hasBedrockAPIKey = true
            AppPreferences.shared.bedrockLastErrorMessage = nil
            AppPreferences.shared.bedrockLastErrorDate = nil
            bedrockLastErrorMessage = nil
            bedrockLastErrorDate = nil
            let estimate = BedrockPricing.estimateUSD(
                modelID: bedrockModelID,
                inputTokens: result.inputTokens,
                outputTokens: result.outputTokens
            ).map { " · ~\(BedrockPricing.formatUSD($0))" } ?? ""
            bedrockStatus = "Connected · \(result.inputTokens ?? 0) in / \(result.outputTokens ?? 0) out\(estimate) for this test."
        } catch {
            hasBedrockAPIKey = ((try? BedrockCredentialStore.loadAPIKey()) ?? nil) != nil
            bedrockStatus = "Connection failed: \(error.localizedDescription)"
            AppPreferences.shared.bedrockLastErrorMessage = error.localizedDescription
            AppPreferences.shared.bedrockLastErrorDate = Date()
            bedrockLastErrorMessage = error.localizedDescription
            bedrockLastErrorDate = AppPreferences.shared.bedrockLastErrorDate
        }
    }

    @MainActor
    func refreshBedrockUsage() async {
        let now = Date()
        let components = Calendar.current.dateComponents([.year, .month], from: now)
        let monthStart = Calendar.current.date(from: components) ?? now
        var usage = (try? await RecordingStore.shared.bedrockUsage(since: monthStart))
            ?? BedrockUsageSummary()
        usage.add(FilterAssistantUsageStore.usage(since: monthStart))
        bedrockUsageSummary = usage
        tokenEfficiencySummary = (try? await RecordingStore.shared.tokenEfficiency(since: monthStart))
            ?? .empty
        bedrockLastErrorMessage = AppPreferences.shared.bedrockLastErrorMessage
        bedrockLastErrorDate = AppPreferences.shared.bedrockLastErrorDate
    }

    func useRecommendedBedrockDefaults() {
        bedrockRegion = BedrockCleanupConfiguration.defaultRegion
        bedrockModelID = BedrockCleanupConfiguration.defaultModelID
        bedrockTimeoutSeconds = BedrockCleanupConfiguration.defaultTimeout
    }

    func clearBedrockCredential() {
        do {
            try BedrockCredentialStore.deleteAPIKey()
            bedrockAPIKeyInput = ""
            hasBedrockAPIKey = false
            bedrockStatus = "Bedrock API key removed from Keychain."
            AppPreferences.shared.bedrockLastErrorMessage = nil
            AppPreferences.shared.bedrockLastErrorDate = nil
            bedrockLastErrorMessage = nil
            bedrockLastErrorDate = nil
        } catch {
            bedrockStatus = error.localizedDescription
        }
    }
    
    func initializeFluidAudioModels() {
        downloadableFluidAudioModels = SettingsFluidAudioModels.availableModels.map { model in
            var updatedModel = model
            updatedModel.isDownloaded = isFluidAudioModelDownloaded(version: model.version)
            return updatedModel
        }
    }
    
    func isFluidAudioModelDownloaded(version: String) -> Bool {
        let asrVersion: AsrModelVersion = version == "v2" ? .v2 : .v3
        
        // Используем правильный путь к кэшу согласно документации:
        // ~/Library/Application Support/FluidAudio/Models/<version-folder>/
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: asrVersion)
        
        // Проверяем наличие всех необходимых файлов модели
        return AsrModels.modelsExist(at: cacheDirectory, version: asrVersion)
    }
    
    func initializeDownloadableModels() {
        let modelManager = WhisperModelManager.shared
        downloadableModels = SettingsDownloadableModels.availableModels.map { model in
            var updatedModel = model
            let filename = model.filename
            updatedModel.isDownloaded = modelManager.isModelDownloaded(name: filename)
            return updatedModel
        }
    }
    
    func loadAvailableModels() {
        availableModels = WhisperModelManager.shared.getAvailableModels()
        if selectedModelURL == nil {
            selectedModelURL = availableModels.first
        }
        initializeDownloadableModels()
    }
    
    @MainActor
    func downloadModel(_ model: SettingsDownloadableModel) async throws {
        guard !isDownloading else { return }
        try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        downloadTask = Task { [self] in
            do {
                let filename = model.filename
                
                try await WhisperModelManager.shared.downloadModel(url: model.url, name: filename) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        
                        self.downloadProgress = progress
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = progress
                            if progress >= 1.0 {
                                self.downloadableModels[index].isDownloaded = true
                            }
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = 0.0
                        }
                    }
                    return
                }
                
                await MainActor.run {
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].isDownloaded = true
                        downloadableModels[index].downloadProgress = 0.0
                    }
                    loadAvailableModels()
                    let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(filename).path
                    selectModel(URL(fileURLWithPath: modelPath))
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    
                    Task { @MainActor in
                        TranscriptionService.shared.reloadModel(with: modelPath)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
                throw error
            }
        }
        
        try await downloadTask?.value
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        if let modelName = downloadingModelName {
            if selectedEngine == "whisper", let model = downloadableModels.first(where: { $0.name == modelName }) {
                let filename = model.filename
                WhisperModelManager.shared.cancelDownload(name: filename)
            }
            // Reset progress for the downloading model
            if let index = downloadableModels.firstIndex(where: { $0.name == modelName }) {
                downloadableModels[index].downloadProgress = 0.0
            }
            if let index = downloadableFluidAudioModels.firstIndex(where: { $0.name == modelName }) {
                downloadableFluidAudioModels[index].downloadProgress = 0.0
            }
        }
        isDownloading = false
        downloadingModelName = nil
        downloadProgress = 0.0
    }
    
    @MainActor
    func downloadFluidAudioModel(_ model: SettingsFluidAudioModel) async throws {
        guard !isDownloading else { return }
        try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
            downloadableFluidAudioModels[index].downloadProgress = 0.0
        }
        
        var wasCancelled = false
        
        downloadTask = Task { [self] in
            do {
                let version: AsrModelVersion = model.version == "v2" ? .v2 : .v3
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let modelId = model.id
                let models = try await AsrModels.downloadAndLoad(version: version) { [weak self] progress in
                    print("[ParakeetProgress] fraction=\(progress.fractionCompleted) phase=\(progress.phase)")
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        self.downloadProgress = progress.fractionCompleted
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == modelId }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = progress.fractionCompleted
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                
                await MainActor.run {
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].isDownloaded = true
                        downloadableFluidAudioModels[index].downloadProgress = 1.0
                    }
                    fluidAudioModelVersion = model.version
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 1.0
                    
                    Task { @MainActor in
                        TranscriptionService.shared.reloadEngine()
                    }
                }
            } catch is CancellationError {
                wasCancelled = true
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].downloadProgress = 0.0
                    }
                }
                // Don't re-throw CancellationError - it's a manual cancellation
            } catch {
                // Check if we were cancelled before the error occurred
                if Task.isCancelled {
                    wasCancelled = true
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                } else {
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw error
                }
            }
        }
        
        // Handle cancellation gracefully - don't throw if cancelled
        do {
            try await downloadTask?.value
        } catch is CancellationError {
            // Already handled in catch block above, just consume the error
            wasCancelled = true
        } catch {
            // If we were cancelled, don't throw
            if !wasCancelled {
                throw error
            }
        }
    }
    
    @MainActor
    func downloadFluidAudioModel() async throws {
        let versionString = AppPreferences.shared.fluidAudioModelVersion
        if let model = downloadableFluidAudioModels.first(where: { $0.version == versionString }) {
            try await downloadFluidAudioModel(model)
        }
    }
}

/// One speech model the picker can select: a Parakeet version or a Whisper
/// model file in the models folder.
enum SpeechModelChoice: Hashable {
    case parakeet(version: String)
    case whisper(filename: String)
}

struct SpeechModelOption: Identifiable, Hashable {
    let choice: SpeechModelChoice
    let name: String
    var id: SpeechModelChoice { choice }
}

extension SettingsViewModel {
    var currentSpeechModel: SpeechModelChoice {
        selectedEngine == "whisper"
            ? .whisper(filename: selectedModelURL?.lastPathComponent ?? "")
            : .parakeet(version: fluidAudioModelVersion)
    }

    /// Downloaded models, plus the current one even when its files are
    /// missing, so the picker always shows what is selected.
    var speechModelOptions: [SpeechModelOption] {
        var options = downloadableFluidAudioModels
            .filter(\.isDownloaded)
            .map { SpeechModelOption(choice: .parakeet(version: $0.version), name: $0.name) }
        options += availableModels.map {
            SpeechModelOption(choice: .whisper(filename: $0.lastPathComponent), name: speechModelName(.whisper(filename: $0.lastPathComponent)))
        }
        let current = currentSpeechModel
        if !options.contains(where: { $0.choice == current }) {
            options.insert(SpeechModelOption(choice: current, name: "\(speechModelName(current)) (not downloaded)"), at: 0)
        }
        return options
    }

    func speechModelName(_ choice: SpeechModelChoice) -> String {
        switch choice {
        case .parakeet(let version):
            return SettingsFluidAudioModels.availableModels.first { $0.version == version }?.name ?? "Parakeet \(version)"
        case .whisper(let filename):
            if filename.isEmpty { return "Whisper" }
            if let known = SettingsDownloadableModels.availableModels.first(where: { $0.filename == filename }) {
                return "Whisper \(known.name)"
            }
            return (filename as NSString).deletingPathExtension
        }
    }

    func speechModelDetail(_ choice: SpeechModelChoice) -> String {
        switch choice {
        case .parakeet(let version):
            let description = SettingsFluidAudioModels.availableModels.first { $0.version == version }?.description
            return [description, "Runs on this Mac"].compactMap { $0 }.joined(separator: " · ")
        case .whisper(let filename):
            let description = SettingsDownloadableModels.availableModels.first { $0.filename == filename }?.description
            return [description ?? "Whisper model file", "Runs on this Mac"].joined(separator: " · ")
        }
    }

    /// Switches engine and model together, so choosing a model never leaves
    /// the other engine loaded.
    func useSpeechModel(_ choice: SpeechModelChoice) {
        switch choice {
        case .parakeet(let version):
            if fluidAudioModelVersion != version { fluidAudioModelVersion = version }
            if selectedEngine != "fluidaudio" { selectedEngine = "fluidaudio" }
        case .whisper(let filename):
            guard !filename.isEmpty else { return }
            if selectedModelURL?.lastPathComponent != filename {
                let url = availableModels.first { $0.lastPathComponent == filename }
                    ?? WhisperModelManager.shared.modelsDirectory.appendingPathComponent(filename)
                selectModel(url)
            }
            if selectedEngine != "whisper" { selectedEngine = "whisper" }
        }
    }
}

struct SettingsDownloadableModel: Identifiable {
    let id = UUID()
    let name: String
    var isDownloaded: Bool
    let url: URL
    let size: Int
    let description: String
    var downloadProgress: Double = 0.0
    let filename: String
    let preferredLanguage: String?

    var sizeString: String {
        formatModelSize(megabytes: size)
    }

    var huggingFacePageURL: URL? {
        makeHuggingFacePageURL(fromDownloadURL: url)
    }

    init(name: String, isDownloaded: Bool, url: URL, size: Int, description: String,
         filename: String? = nil, preferredLanguage: String? = nil) {
        self.name = name
        self.isDownloaded = isDownloaded
        self.url = url
        self.size = size
        self.description = description
        self.filename = filename ?? url.lastPathComponent
        self.preferredLanguage = preferredLanguage
    }
}

struct SettingsDownloadableModels {
    static let availableModels = [
        SettingsDownloadableModel(
            name: "Turbo V3 large",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
            size: 1624,
            description: "High accuracy, best quality"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 medium",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
            size: 874,
            description: "Balanced speed and accuracy"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 small",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
            size: 574,
            description: "Fastest processing"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 Hebrew",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin?download=true")!,
            size: 1624,
            description: "Hebrew fine-tune of Turbo V3 by ivrit.ai. Sets the language to Hebrew.",
            filename: "ggml-ivrit-large-v3-turbo.bin",
            preferredLanguage: "he"
        )
    ]

    static func preferredLanguage(forFilename filename: String) -> String? {
        availableModels.first { $0.filename == filename }?.preferredLanguage
    }

    static func isVisible(_ model: SettingsDownloadableModel,
                          selectedLanguage: String,
                          systemLanguage: String) -> Bool {
        guard let lang = model.preferredLanguage else { return true }
        if model.isDownloaded { return true }
        return selectedLanguage == lang || systemLanguage == lang
    }
}

func countLabel(_ count: Int, singular: String, plural: String) -> String {
    count == 1 ? "\(count) \(singular)" : "\(count) \(plural)"
}

func formatModelSize(megabytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(megabytes) * 1000000)
}

func makeHuggingFacePageURL(fromDownloadURL url: URL) -> URL? {
    let absoluteString = url.absoluteString
    guard let range = absoluteString.range(of: "/resolve/") else { return nil }
    return URL(string: String(absoluteString[..<range.lowerBound]))
}

/// The Hugging Face owner (user / organization) from a model page URL,
/// e.g. https://huggingface.co/ivrit-ai/whisper-... -> "ivrit-ai".
func huggingFaceOwner(fromPageURL url: URL) -> String? {
    url.pathComponents.first { $0 != "/" }
}

struct Settings {
    static let asianLanguages: Set<String> = ["zh", "ja", "ko"]
    
    var selectedLanguage: String
    var suppressBlankAudio: Bool
    var showTimestamps: Bool
    var temperature: Double
    var noSpeechThreshold: Double
    var initialPrompt: String
    var useBeamSearch: Bool
    var beamSize: Int
    var useAsianAutocorrect: Bool
    
    var isAsianLanguage: Bool {
        Settings.asianLanguages.contains(selectedLanguage)
    }
    
    var shouldApplyAsianAutocorrect: Bool {
        isAsianLanguage && useAsianAutocorrect
    }
    
    init() {
        let prefs = AppPreferences.shared
        self.selectedLanguage = prefs.whisperLanguage
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
    }
}

struct SettingsFluidAudioModel: Identifiable {
    let id = UUID()
    let name: String
    let version: String
    var isDownloaded: Bool
    let description: String
    let size: Int
    var downloadProgress: Double = 0.0

    var sizeString: String {
        formatModelSize(megabytes: size)
    }
}

struct SettingsFluidAudioModels {
    static let availableModels = [
        SettingsFluidAudioModel(
            name: "Parakeet v3",
            version: "v3",
            isDownloaded: false,
            description: "Multilingual, 25 languages",
            size: 483
        ),
        SettingsFluidAudioModel(
            name: "Parakeet v2",
            version: "v2",
            isDownloaded: false,
            description: "English-only, higher recall",
            size: 464
        )
    ]
}

enum OnboardingModelType {
    case whisper(url: URL, size: Int)
    case parakeet(version: String)
}

struct OnboardingUnifiedModel: Identifiable {
    let id = UUID()
    let name: String
    var isDownloaded: Bool
    let description: String
    let type: OnboardingModelType
    var downloadProgress: Double = 0.0

    var sizeMegabytes: Int? {
        switch type {
        case .whisper(_, let size):
            return size
        case .parakeet(let version):
            return SettingsFluidAudioModels.availableModels
                .first(where: { $0.version == version })?
                .size
        }
    }

    var sizeString: String {
        guard let sizeMegabytes else { return "Size unknown" }
        return formatModelSize(megabytes: sizeMegabytes)
    }

    var huggingFacePageURL: URL? {
        switch type {
        case .whisper(let url, _):
            return makeHuggingFacePageURL(fromDownloadURL: url)
        case .parakeet(let version):
            let repo = version == "v2" ? "parakeet-tdt-0.6b-v2-coreml" : "parakeet-tdt-0.6b-v3-coreml"
            return URL(string: "https://huggingface.co/FluidInference/\(repo)")
        }
    }
}

struct OnboardingUnifiedModels {
    static let availableModels = [
        OnboardingUnifiedModel(
            name: "Whisper V3 Large",
            isDownloaded: false,
            description: "High accuracy, best quality",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
                size: 1624
            )
        ),
        OnboardingUnifiedModel(
            name: "Parakeet v3",
            isDownloaded: false,
            description: "Fastest processing and accurate",
            type: .parakeet(version: "v3")
        ),
        OnboardingUnifiedModel(
            name: "Parakeet v2",
            isDownloaded: false,
            description: "Fastest processing and English-only, higher recall",
            type: .parakeet(version: "v2")
        ),
        OnboardingUnifiedModel(
            name: "Whisper Medium",
            isDownloaded: false,
            description: "Balanced speed and accuracy",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
                size: 874
            )
        ),
        OnboardingUnifiedModel(
            name: "Whisper Small",
            isDownloaded: false,
            description: "Very fast processing",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
                size: 574
            )
        )
    ]
}
