import Foundation

struct TranscriptCleanupOutcome: Equatable {
    enum Source: String, Codable, Equatable {
        case bedrock
        case rawFallback
        case disabled
    }

    let text: String
    let source: Source
    let inputTokens: Int?
    let outputTokens: Int?
    let modelID: String?
}

final class TranscriptCleanupPipeline {
    static let shared = TranscriptCleanupPipeline()

    private let service: BedrockCleanupService
    private let isEnabled: () -> Bool
    private let credentialProvider: () throws -> String?
    private let configurationProvider: () -> BedrockCleanupConfiguration

    init(
        service: BedrockCleanupService = .shared,
        isEnabled: @escaping () -> Bool = { AppPreferences.shared.bedrockCleanupEnabled },
        credentialProvider: @escaping () throws -> String? = { try BedrockCredentialStore.loadAPIKey() },
        configurationProvider: @escaping () -> BedrockCleanupConfiguration = {
            let prefs = AppPreferences.shared
            return BedrockCleanupConfiguration(
                region: prefs.bedrockRegion,
                modelID: prefs.bedrockModelID,
                timeout: prefs.bedrockTimeoutSeconds
            )
        }
    ) {
        self.service = service
        self.isEnabled = isEnabled
        self.credentialProvider = credentialProvider
        self.configurationProvider = configurationProvider
    }

    func finalize(_ rawTranscript: String) async -> TranscriptCleanupOutcome {
        guard isEnabled() else {
            return TranscriptCleanupOutcome(
                text: rawTranscript,
                source: .disabled,
                inputTokens: nil,
                outputTokens: nil,
                modelID: nil
            )
        }

        let storedToken = try? credentialProvider()
        guard let token = storedToken ?? nil, !token.isEmpty else {
            recordFailure("No Bedrock API key is stored.")
            return TranscriptCleanupOutcome(
                text: rawTranscript,
                source: .rawFallback,
                inputTokens: nil,
                outputTokens: nil,
                modelID: nil
            )
        }

        let configuration = configurationProvider()

        do {
            let result = try await service.clean(
                transcript: rawTranscript,
                apiKey: token,
                configuration: configuration
            )
            clearFailure()
            return TranscriptCleanupOutcome(
                text: result.text,
                source: .bedrock,
                inputTokens: result.inputTokens,
                outputTokens: result.outputTokens,
                modelID: configuration.modelID
            )
        } catch {
            print("Bedrock cleanup unavailable; using raw transcript: \(error.localizedDescription)")
            recordFailure(error.localizedDescription)
            return TranscriptCleanupOutcome(
                text: rawTranscript,
                source: .rawFallback,
                inputTokens: nil,
                outputTokens: nil,
                modelID: nil
            )
        }
    }

    private func recordFailure(_ message: String) {
        AppPreferences.shared.bedrockLastErrorMessage = message
        AppPreferences.shared.bedrockLastErrorDate = Date()
    }

    private func clearFailure() {
        AppPreferences.shared.bedrockLastErrorMessage = nil
        AppPreferences.shared.bedrockLastErrorDate = nil
    }
}
