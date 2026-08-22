import Foundation

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    
    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@propertyWrapper
struct OptionalUserDefault<T> {
    let key: String
    
    var wrappedValue: T? {
        get { UserDefaults.standard.object(forKey: key) as? T }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

final class AppPreferences {
    static let shared = AppPreferences()
    private init() {
        RenamedAppMigration.migratePreferences()
        Self.migrateOldPreferences()
    }
    
    static func migrateOldPreferences(in defaults: UserDefaults = .standard) {
        if let oldPath = defaults.string(forKey: "selectedModelPath"),
           defaults.string(forKey: "selectedWhisperModelPath") == nil {
            defaults.set(oldPath, forKey: "selectedWhisperModelPath")
        }

        if defaults.string(forKey: "bedrockModelID") == BedrockCleanupConfiguration.legacyOnDemandModelID {
            defaults.set(BedrockCleanupConfiguration.defaultModelID, forKey: "bedrockModelID")
        }
    }
    
    // Engine settings
    @UserDefault(key: "selectedEngine", defaultValue: "fluidaudio")
    var selectedEngine: String
    
    // Model settings
    var selectedModelPath: String? {
        get {
            if selectedEngine == "whisper" {
                return selectedWhisperModelPath
            }
            return nil
        }
        set {
            if selectedEngine == "whisper" {
                selectedWhisperModelPath = newValue
            }
        }
    }
    
    @OptionalUserDefault(key: "selectedWhisperModelPath")
    var selectedWhisperModelPath: String?
    
    @UserDefault(key: "fluidAudioModelVersion", defaultValue: "v3")
    var fluidAudioModelVersion: String
    
    @UserDefault(key: "qwen3Variant", defaultValue: "f32")
    var qwen3Variant: String
    
    @UserDefault(key: "whisperLanguage", defaultValue: "en")
    var whisperLanguage: String
    
    // Transcription settings
    @UserDefault(key: "suppressBlankAudio", defaultValue: true)
    var suppressBlankAudio: Bool
    
    @UserDefault(key: "showTimestamps", defaultValue: false)
    var showTimestamps: Bool
    
    @UserDefault(key: "temperature", defaultValue: 0.0)
    var temperature: Double
    
    @UserDefault(key: "noSpeechThreshold", defaultValue: 0.6)
    var noSpeechThreshold: Double
    
    @UserDefault(key: "initialPrompt", defaultValue: "")
    var initialPrompt: String
    
    @UserDefault(key: "useBeamSearch", defaultValue: false)
    var useBeamSearch: Bool
    
    @UserDefault(key: "beamSize", defaultValue: 5)
    var beamSize: Int
    
    @UserDefault(key: "debugMode", defaultValue: false)
    var debugMode: Bool
    
    @UserDefault(key: "playSoundOnRecordStart", defaultValue: false)
    var playSoundOnRecordStart: Bool
    
    @UserDefault(key: "hasCompletedOnboarding", defaultValue: false)
    var hasCompletedOnboarding: Bool
    
    @UserDefault(key: "useAsianAutocorrect", defaultValue: true)
    var useAsianAutocorrect: Bool
    
    @OptionalUserDefault(key: "selectedMicrophoneData")
    var selectedMicrophoneData: Data?
    
    @UserDefault(key: "modifierOnlyHotkey", defaultValue: "fn")
    var modifierOnlyHotkey: String
    
    /// Last non-none modifier key, used to restore the user's choice
    /// when switching back to Single Modifier Key mode.
    @UserDefault(key: "lastModifierOnlyHotkey", defaultValue: "fn")
    var lastModifierOnlyHotkey: String
    
    @UserDefault(key: "mouseButtonHotkey", defaultValue: "none")
    var mouseButtonHotkey: String


    @UserDefault(key: "holdToRecord", defaultValue: true)
    var holdToRecord: Bool

    @UserDefault(key: "doublePressToTrigger", defaultValue: false)
    var doublePressToTrigger: Bool
    
    @UserDefault(key: "addSpaceAfterSentence", defaultValue: true)
    var addSpaceAfterSentence: Bool

    // Clipboard settings
    @UserDefault(key: "autoCopyToClipboard", defaultValue: false)
    var autoCopyToClipboard: Bool

    @UserDefault(key: "autoPasteTranscription", defaultValue: true)
    var autoPasteTranscription: Bool

    // Bedrock cleanup settings. The API key is stored separately in Keychain.
    @UserDefault(key: "bedrockCleanupEnabled", defaultValue: true)
    var bedrockCleanupEnabled: Bool

    @UserDefault(key: "bedrockRegion", defaultValue: BedrockCleanupConfiguration.defaultRegion)
    var bedrockRegion: String

    @UserDefault(key: "bedrockModelID", defaultValue: BedrockCleanupConfiguration.defaultModelID)
    var bedrockModelID: String

    @UserDefault(key: "bedrockTimeoutSeconds", defaultValue: BedrockCleanupConfiguration.defaultTimeout)
    var bedrockTimeoutSeconds: Double

    @UserDefault(key: "cleanupProviderID", defaultValue: CleanupProviderID.bedrock.rawValue)
    var cleanupProviderID: String

    @UserDefault(key: "ollamaBaseURL", defaultValue: "http://localhost:11434")
    var ollamaBaseURL: String

    @UserDefault(key: "ollamaModelID", defaultValue: "llama3.2:3b")
    var ollamaModelID: String

    @UserDefault(key: "ollamaTimeoutSeconds", defaultValue: 15.0)
    var ollamaTimeoutSeconds: Double

    @UserDefault(key: "openAICompatibleBaseURL", defaultValue: "https://api.openai.com/v1")
    var openAICompatibleBaseURL: String

    @UserDefault(key: "openAICompatibleModelID", defaultValue: "gpt-4.1-nano")
    var openAICompatibleModelID: String

    @UserDefault(key: "openAICompatibleTimeoutSeconds", defaultValue: 10.0)
    var openAICompatibleTimeoutSeconds: Double

    @OptionalUserDefault(key: "personalVocabularyData")
    var personalVocabularyData: Data?

    @OptionalUserDefault(key: "targetAppRulesData")
    var targetAppRulesData: Data?

    @UserDefault(key: "meetingCleanupEnabled", defaultValue: false)
    var meetingCleanupEnabled: Bool

    @OptionalUserDefault(key: "bedrockLastErrorMessage")
    var bedrockLastErrorMessage: String?

    @OptionalUserDefault(key: "bedrockLastErrorDate")
    var bedrockLastErrorDate: Date?

    @UserDefault(key: "launchAtLogin", defaultValue: true)
    var launchAtLogin: Bool

    @UserDefault(key: "escCancelWithoutConfirmation", defaultValue: false)
    var escCancelWithoutConfirmation: Bool

    @UserDefault(key: "startHiddenInMenuBar", defaultValue: true)
    var startHiddenInMenuBar: Bool

    @UserDefault(key: "autoDeleteRecordingsEnabled", defaultValue: false)
    var autoDeleteRecordingsEnabled: Bool

    @UserDefault(key: "autoDeleteRecordingsAfterDays", defaultValue: 30)
    var autoDeleteRecordingsAfterDays: Int
}
