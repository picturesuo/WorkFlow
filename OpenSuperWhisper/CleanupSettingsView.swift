import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Cleanup

/// How AI cleanup writes: the master switch, the four built-in modes, and
/// saved custom filters. Where it runs and what it costs live in Provider & Cost.
struct CleanupSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onShowProvider: () -> Void

    private var writingFilter = WritingFilterPreferences()
    @State private var meetingCleanupEnabled = AppPreferences.shared.meetingCleanupEnabled

    init(viewModel: SettingsViewModel, onShowProvider: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onShowProvider = onShowProvider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPaneHeader(
                title: "Cleanup",
                subtitle: "AI cleanup turns what you said into text that reads the way you want."
            )
            cleanupSwitch
            modes
            CustomCleanupFiltersCard(writingFilter: writingFilter)
                .padding(16)
                .settingsSurface()
            SettingsGroup(
                footer: "Audio never leaves this Mac; only text goes to your provider. If cleanup fails, runs out of time, or would change your meaning, WorkFlow keeps your original transcript."
            ) {
                SettingsToggleRow(
                    title: "Clean up meeting transcripts",
                    detail: "Off keeps long meetings on this Mac and free.",
                    isOn: $meetingCleanupEnabled
                )
            }
        }
        .onChange(of: meetingCleanupEnabled) { _, value in AppPreferences.shared.meetingCleanupEnabled = value }
    }

    private var destination: CleanupProviderDestination {
        CleanupProviderFactory.selectedDestination()
    }

    private var hasKeyForSelectedProvider: Bool {
        switch destination.providerID {
        case .bedrock: viewModel.hasBedrockAPIKey
        case .ollama: true
        case .openAICompatible: viewModel.hasCompatibleAPIKey || destination.isOnThisMac
        case .azureOpenAI: viewModel.hasAzureAPIKey
        }
    }

    private var cleanupSwitch: some View {
        SettingsGroup {
            SettingsRow(
                title: "AI cleanup",
                detail: viewModel.bedrockCleanupEnabled
                    ? "Runs on \(ProviderCostSettingsView.summary(of: destination))."
                    : "Off: dictations are pasted as recognized, with your vocabulary applied. Modes and filters need cleanup on."
            ) {
                Toggle("AI cleanup", isOn: $viewModel.bedrockCleanupEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("AI cleanup")
                    .accessibilityHint("Rewrites new dictations in the selected writing mode")
            }
            SettingsDivider()
            if viewModel.bedrockCleanupEnabled, !hasKeyForSelectedProvider {
                SettingsNotice(
                    title: "Add your \(destination.providerID.displayName) key",
                    detail: "Until then, dictations keep their original transcript."
                ) {
                    SettingsLinkButton(title: "Provider & Cost", action: onShowProvider)
                }
            } else if viewModel.bedrockCleanupEnabled, viewModel.bedrockLastErrorMessage != nil {
                SettingsNotice(
                    title: "The last cleanup request didn’t finish",
                    detail: "That dictation kept its original transcript."
                ) {
                    SettingsLinkButton(title: "Check connection", action: onShowProvider)
                }
            } else {
                HStack {
                    Text("Connection and estimated cost")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    SettingsLinkButton(title: "Provider & Cost ›", action: onShowProvider)
                        .accessibilityLabel("Open Provider & Cost")
                }
                .settingsRowPadding()
            }
        }
    }

    private var modes: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Writing mode")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(CleanupMode.allCases) { mode in
                    WritingModeCard(
                        mode: mode,
                        isSelected: writingFilter.selection == .builtIn(mode)
                    ) {
                        writingFilter.selectionBinding.wrappedValue = .builtIn(mode)
                    }
                }
            }
            Text("Each example shows the style a mode aims for. Your choice applies to new dictations and is also in the main window and menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }
}

/// A built-in mode as a selectable card with a short spoken → written example.
struct WritingModeCard: View {
    let mode: CleanupMode
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(mode.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 4)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? ThemePalette.ink(colorScheme) : Color.secondary.opacity(0.45))
                }
                Text(mode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(mode.example.spoken)”")
                        .foregroundStyle(.secondary)
                    Text(mode.example.written)
                        .foregroundStyle(.primary)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ThemePalette.panelSurface(colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(ThemePalette.cardBackground(colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? ThemePalette.ink(colorScheme) : ThemePalette.cardBorder(colorScheme), lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mode.displayName) writing mode")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(mode.description)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension CleanupMode {
    /// One line for a mode card; `description` stays the full help text.
    var summary: String {
        switch self {
        case .homework: "Complete explanations that keep every idea, with quantities as digits."
        case .technical: "Compact, unambiguous instructions for computers and coding agents."
        case .everyday: "A light pass that keeps your natural voice and level of detail."
        case .writing: "Your own voice for essays and posts; only stutters and filler go."
        }
    }

    /// Illustrates the style the mode's instructions ask for. It is not
    /// output from any provider.
    var example: (spoken: String, written: String) {
        switch self {
        case .homework: ("the price went up ten percent in twenty twenty six", "The price went up 10% in 2026.")
        case .technical: ("okay so can you, um, make the search faster and also add tests", "Make the search faster and add tests.")
        case .everyday: ("um so I think we should, we should meet on Friday", "I think we should meet on Friday.")
        case .writing: ("I went running in the, in the spring and I noticed, um, the mornings were cooler", "I went running in the spring and I noticed the mornings were cooler.")
        }
    }
}

// MARK: - Provider & Cost

/// Where cleanup runs and what WorkFlow estimates it costs: the provider and
/// its secure key, the monthly estimated-cost stop, and this month's usage.
struct ProviderCostSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onShowCleanup: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    @State private var providerID: CleanupProviderID
    @State private var ollamaBaseURL: String
    @State private var ollamaModelID: String
    @State private var ollamaTimeout: Double
    @State private var compatibleBaseURL: String
    @State private var compatibleModelID: String
    @State private var compatibleTimeout: Double
    @State private var compatibleAPIKey = ""
    @State private var azureEndpoint: String
    @State private var azureDeployment: String
    @State private var azureTimeout: Double
    @State private var azureReasoningDeployment: Bool
    @State private var azureAPIKey = ""
    @State private var providerStatus = ""
    @State private var isTesting = false
    @State private var showsUsage = false
    @State private var keyPendingRemoval: CleanupProviderID?

    init(viewModel: SettingsViewModel, onShowCleanup: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onShowCleanup = onShowCleanup
        let prefs = AppPreferences.shared
        _providerID = State(initialValue: CleanupProviderID(rawValue: prefs.cleanupProviderID) ?? .bedrock)
        _ollamaBaseURL = State(initialValue: prefs.ollamaBaseURL)
        _ollamaModelID = State(initialValue: prefs.ollamaModelID)
        _ollamaTimeout = State(initialValue: prefs.ollamaTimeoutSeconds)
        _compatibleBaseURL = State(initialValue: prefs.openAICompatibleBaseURL)
        _compatibleModelID = State(initialValue: prefs.openAICompatibleModelID)
        _compatibleTimeout = State(initialValue: prefs.openAICompatibleTimeoutSeconds)
        _azureEndpoint = State(initialValue: prefs.azureOpenAIEndpoint)
        _azureDeployment = State(initialValue: prefs.azureOpenAIDeployment)
        _azureTimeout = State(initialValue: prefs.azureOpenAITimeoutSeconds)
        _azureReasoningDeployment = State(initialValue: prefs.azureOpenAIReasoningDeployment)
    }

    /// "Amazon Bedrock · Nova Micro", naming the priced model plainly.
    static func summary(of destination: CleanupProviderDestination) -> String {
        if destination.providerID == .bedrock, BedrockPricing.supports(modelID: destination.model) {
            return "Amazon Bedrock · Nova Micro"
        }
        return destination.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPaneHeader(
                title: "Provider & Cost",
                subtitle: "Where AI cleanup runs, and what WorkFlow estimates it costs."
            )
            providerGroup
            if let lastError = viewModel.bedrockLastErrorMessage {
                lastErrorGroup(lastError)
            }
            costGroup
        }
        .task { await viewModel.refreshBedrockUsage() }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingsDidUpdateNotification)) { _ in
            Task { await viewModel.refreshBedrockUsage() }
        }
        .onChange(of: providerID) { _, value in
            AppPreferences.shared.cleanupProviderID = value.rawValue
            providerStatus = ""
        }
        .onChange(of: ollamaBaseURL) { _, value in AppPreferences.shared.ollamaBaseURL = value }
        .onChange(of: ollamaModelID) { _, value in AppPreferences.shared.ollamaModelID = value }
        .onChange(of: ollamaTimeout) { _, value in AppPreferences.shared.ollamaTimeoutSeconds = value }
        .onChange(of: compatibleBaseURL) { _, value in AppPreferences.shared.openAICompatibleBaseURL = value }
        .onChange(of: compatibleModelID) { _, value in AppPreferences.shared.openAICompatibleModelID = value }
        .onChange(of: compatibleTimeout) { _, value in AppPreferences.shared.openAICompatibleTimeoutSeconds = value }
        .onChange(of: azureEndpoint) { _, value in AppPreferences.shared.azureOpenAIEndpoint = value }
        .onChange(of: azureDeployment) { _, value in AppPreferences.shared.azureOpenAIDeployment = value }
        .onChange(of: azureTimeout) { _, value in AppPreferences.shared.azureOpenAITimeoutSeconds = value }
        .onChange(of: azureReasoningDeployment) { _, value in AppPreferences.shared.azureOpenAIReasoningDeployment = value }
        .confirmationDialog(
            "Remove the \(keyPendingRemoval?.displayName ?? "") key from Keychain?",
            isPresented: Binding(
                get: { keyPendingRemoval != nil },
                set: { if !$0 { keyPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: keyPendingRemoval
        ) { provider in
            Button("Remove Key", role: .destructive) { removeKey(for: provider) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Cleanup with this provider stops until you add a key again. Dictations keep their original transcript.")
        }
    }

    // MARK: Provider

    private var providerGroup: some View {
        SettingsGroup(
            title: "Provider",
            footer: "Keys are kept in macOS Keychain and remote providers must use HTTPS. Audio never leaves this Mac; only transcript text is sent."
        ) {
            SettingsRow(title: "Cleanup provider", detail: providerDetail) {
                Picker("Cleanup provider", selection: $providerID) {
                    ForEach(CleanupProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            if !viewModel.bedrockCleanupEnabled {
                SettingsDivider()
                SettingsNotice(
                    title: "AI cleanup is off",
                    detail: "You can connect a provider now and turn cleanup on in Cleanup."
                ) {
                    SettingsLinkButton(title: "Cleanup", action: onShowCleanup)
                }
            }
            SettingsDivider()
            switch providerID {
            case .bedrock: bedrockFields
            case .ollama: ollamaFields
            case .openAICompatible: compatibleFields
            case .azureOpenAI: azureFields
            }
            if !currentStatus.isEmpty {
                Text(currentStatus)
                    .font(.caption)
                    .foregroundStyle(currentStatus.localizedCaseInsensitiveContains("failed") ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .accessibilityLabel("Connection status: \(currentStatus)")
            }
        }
    }

    private var providerDetail: String {
        switch providerID {
        case .bedrock: "Pay as you go on your AWS account. Nova Micro is the recommended low-cost model."
        case .ollama: "Runs on this Mac. No account, key, or API bill."
        case .openAICompatible: "OpenAI, OpenRouter, LM Studio, or any chat-completions service."
        case .azureOpenAI: "A chat deployment in your Azure OpenAI or Microsoft Foundry resource."
        }
    }

    private var bedrockFields: some View {
        Group {
            keyRow(
                title: "API key",
                prompt: "Bedrock API key",
                text: $viewModel.bedrockAPIKeyInput,
                isStored: viewModel.hasBedrockAPIKey,
                accessibilityLabel: "Amazon Bedrock API key",
                link: ("Create a key", URL(string: "https://console.aws.amazon.com/bedrock/home#/api-keys")!)
            )
            SettingsDivider()
            textRow("Region", prompt: "us-east-1", text: $viewModel.bedrockRegion, width: 160)
            SettingsDivider()
            textRow(
                "Model",
                detail: BedrockPricing.supports(modelID: viewModel.bedrockModelID) ? "Nova Micro, with a verified price." : nil,
                prompt: "Model ID",
                text: $viewModel.bedrockModelID,
                width: 240
            )
            SettingsDivider()
            timeoutRow(value: $viewModel.bedrockTimeoutSeconds, range: 0.5...20)
            SettingsDivider()
            actionsRow(
                testTitle: "Save & Test",
                isTesting: viewModel.isTestingBedrock,
                testAccessibility: viewModel.isTestingBedrock ? "Testing Amazon Bedrock connection" : "Save API key and test Amazon Bedrock",
                test: { Task { await viewModel.saveAndTestBedrock() } },
                canRemoveKey: viewModel.hasBedrockAPIKey
            ) {
                Button("Recommended Defaults") { viewModel.useRecommendedBedrockDefaults() }
                    .help("Nova Micro in us-east-1 with a 3-second timeout")
            }
        }
    }

    private var ollamaFields: some View {
        Group {
            SettingsRow(title: "Setup", detail: "Install Ollama, then run `ollama pull \(ollamaModelID)` once in Terminal.") {
                SettingsWebLink("Get Ollama", destination: URL(string: "https://ollama.com/download/mac")!)
            }
            SettingsDivider()
            textRow("Server", prompt: "http://localhost:11434", text: $ollamaBaseURL, width: 240)
            SettingsDivider()
            textRow("Model", prompt: "llama3.2:3b", text: $ollamaModelID, width: 240)
            SettingsDivider()
            timeoutRow(value: $ollamaTimeout, range: 1...60)
            SettingsDivider()
            actionsRow(
                testTitle: "Test Ollama",
                isTesting: isTesting,
                testAccessibility: isTesting ? "Testing Ollama" : "Test Ollama on this Mac",
                test: { Task { await testProvider() } },
                canRemoveKey: false
            ) { EmptyView() }
        }
    }

    private var compatibleFields: some View {
        Group {
            textRow("Base URL", prompt: "https://api.example.com/v1", text: $compatibleBaseURL, width: 240)
            SettingsDivider()
            textRow("Model", prompt: "Provider model ID", text: $compatibleModelID, width: 240)
            SettingsDivider()
            keyRow(
                title: "API key",
                prompt: "API key",
                text: $compatibleAPIKey,
                isStored: viewModel.hasCompatibleAPIKey,
                accessibilityLabel: "OpenAI-compatible API key",
                link: nil
            )
            SettingsDivider()
            timeoutRow(value: $compatibleTimeout, range: 1...60)
            SettingsDivider()
            actionsRow(
                testTitle: "Save & Test",
                isTesting: isTesting,
                testAccessibility: isTesting ? "Testing the OpenAI-compatible connection" : "Save API key and test the OpenAI-compatible connection",
                test: { Task { await testProvider() } },
                canRemoveKey: viewModel.hasCompatibleAPIKey
            ) { EmptyView() }
        }
    }

    private var azureFields: some View {
        Group {
            SettingsRow(title: "Foundry", detail: "Usage bills to your Azure subscription; whether credits apply is up to Microsoft.") {
                SettingsWebLink("Open Foundry", destination: URL(string: "https://ai.azure.com")!)
            }
            SettingsDivider()
            textRow("Endpoint", prompt: "https://YOUR-RESOURCE.openai.azure.com", text: $azureEndpoint, width: 240, accessibilityLabel: "Azure OpenAI endpoint")
            SettingsDivider()
            textRow("Deployment", prompt: "e.g. gpt-4.1-nano", text: $azureDeployment, width: 240, accessibilityLabel: "Azure OpenAI deployment name")
            SettingsDivider()
            keyRow(
                title: "API key",
                prompt: "Azure OpenAI API key",
                text: $azureAPIKey,
                isStored: viewModel.hasAzureAPIKey,
                accessibilityLabel: "Azure OpenAI API key",
                link: nil
            )
            SettingsDivider()
            SettingsToggleRow(
                title: "Reasoning deployment",
                detail: "For o-series or GPT-5, which reject temperature; WorkFlow sends a low reasoning effort instead.",
                isOn: $azureReasoningDeployment
            )
            SettingsDivider()
            timeoutRow(value: $azureTimeout, range: 1...60)
            SettingsDivider()
            actionsRow(
                testTitle: "Save & Test",
                isTesting: isTesting,
                testAccessibility: isTesting ? "Testing Azure OpenAI connection" : "Save API key and test Azure OpenAI",
                test: { Task { await testProvider() } },
                canRemoveKey: viewModel.hasAzureAPIKey
            ) { EmptyView() }
        }
    }

    private func keyRow(
        title: String,
        prompt: String,
        text: Binding<String>,
        isStored: Bool,
        accessibilityLabel: String,
        link: (String, URL)?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WFSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if isStored {
                    Label("Stored in Keychain", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let link {
                    SettingsWebLink(link.0, destination: link.1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SecureField(isStored ? "Enter a new key to replace it" : prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("Saved to macOS Keychain only after a successful connection test")
        }
        .settingsRowPadding()
    }

    private func textRow(
        _ title: String,
        detail: String? = nil,
        prompt: String,
        text: Binding<String>,
        width: CGFloat,
        accessibilityLabel: String? = nil
    ) -> some View {
        SettingsRow(title: title, detail: detail) {
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .accessibilityLabel(accessibilityLabel ?? title)
        }
    }

    private func timeoutRow(value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        SettingsRow(title: "Timeout", detail: "A slower reply keeps your original transcript.") {
            Stepper(value: value, in: range, step: 0.5) {
                Text("\(value.wrappedValue, specifier: "%.1f") s")
                    .font(.callout.monospacedDigit())
            }
            .fixedSize()
            .accessibilityLabel("Timeout")
            .accessibilityValue("\(String(format: "%.1f", value.wrappedValue)) seconds")
        }
    }

    private func actionsRow<Extra: View>(
        testTitle: String,
        isTesting: Bool,
        testAccessibility: String,
        test: @escaping () -> Void,
        canRemoveKey: Bool,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        HStack(spacing: WFSpace.sm) {
            Button(action: test) {
                if isTesting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Testing…")
                    }
                } else {
                    Text(testTitle)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isTesting)
            .accessibilityLabel(testAccessibility)
            extra()
            Spacer(minLength: 0)
            if canRemoveKey {
                Button("Remove Key…", role: .destructive) { keyPendingRemoval = providerID }
            }
        }
        .controlSize(.regular)
        .settingsRowPadding()
    }

    private var currentStatus: String {
        providerID == .bedrock ? viewModel.bedrockStatus : providerStatus
    }

    // MARK: Last error

    private func lastErrorGroup(_ message: String) -> some View {
        SettingsGroup {
            SettingsNotice(
                title: "The last cleanup request didn’t finish",
                detail: message == TranscriptCleanupPipeline.safeFailureMessage
                    ? "That dictation kept its original transcript. Save & Test checks the connection."
                    : message
            ) {
                if let date = viewModel.bedrockLastErrorDate {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: Cost

    private var costGroup: some View {
        let usage = viewModel.bedrockUsageSummary
        let limit = viewModel.bedrockMonthlyBudgetUSD
        let spent = usage.estimatedCostUSD
        let stopEnabled = viewModel.bedrockMonthlyBudgetEnabled
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Estimated cost")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if providerID == .bedrock {
                    SettingsWebLink("AWS pricing", destination: BedrockPricing.pricingURL)
                }
            }
            .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(BedrockPricing.formatUSD(spent))
                            .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("this month")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if stopEnabled {
                            Text("of \(BedrockPricing.formatUSD(limit))")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Estimated cost this month: \(BedrockPricing.formatUSD(spent))\(stopEnabled ? " of a \(BedrockPricing.formatUSD(limit)) stop" : "")")
                    if stopEnabled {
                        ProgressView(value: min(spent, limit), total: max(limit, 0.0001))
                            .tint(spent >= limit ? Color.orange : ThemePalette.ink(colorScheme))
                            .accessibilityHidden(true)
                        Text(spent >= limit
                             ? "Stop reached: Bedrock requests pause until next month."
                             : "\(BedrockPricing.formatUSD(max(0, limit - spent))) left before Bedrock requests pause.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(spent >= limit ? Color.orange : Color.secondary)
                    }
                }
                .settingsRowPadding()
                .padding(.vertical, 4)
                SettingsDivider()
                SettingsRow(
                    title: "Monthly stop",
                    detail: "At this estimate, Bedrock cleanup, filter drafting, and Learn pause until next month, and dictations keep their original transcript. It’s an estimate, not a billing cap."
                ) {
                    HStack(spacing: WFSpace.sm) {
                        if stopEnabled {
                            Stepper(value: $viewModel.bedrockMonthlyBudgetUSD, in: 0.05...10, step: 0.05) {
                                Text(BedrockPricing.formatUSD(viewModel.bedrockMonthlyBudgetUSD))
                                    .font(.callout.monospacedDigit())
                            }
                            .fixedSize()
                            .accessibilityLabel("Stop amount")
                            .accessibilityValue(BedrockPricing.formatUSD(viewModel.bedrockMonthlyBudgetUSD))
                        }
                        Toggle("Monthly stop", isOn: $viewModel.bedrockMonthlyBudgetEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .accessibilityLabel("Monthly estimated-cost stop")
                            .accessibilityHint("Pauses Bedrock requests when this month’s estimate reaches the amount")
                    }
                }
                if providerID == .bedrock, !BedrockPricing.supports(modelID: viewModel.bedrockModelID) {
                    SettingsDivider()
                    SettingsNotice(
                        title: "No verified price for this model",
                        detail: "WorkFlow can’t estimate it, so the stop can’t apply. Recommended Defaults switch to Nova Micro."
                    ) { EmptyView() }
                }
                SettingsDivider()
                SettingsDisclosureRow(
                    title: "Usage this month",
                    detail: "\(countLabel(usage.cleanedDictations, singular: "dictation", plural: "dictations")) cleaned · \(usage.inputTokens + usage.outputTokens) tokens",
                    isExpanded: $showsUsage
                )
                if showsUsage {
                    usageDetails(usage)
                }
            }
            .settingsSurface()
            Text(costFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }

    private var costFooter: String {
        switch providerID {
        case .bedrock:
            "Estimated from token counts at the AWS price checked \(BedrockPricing.asOfDate). Your AWS bill is authoritative."
        case .ollama:
            "Ollama runs on this Mac, so cleanup has no API cost. The stop applies only to Amazon Bedrock."
        case .openAICompatible, .azureOpenAI:
            "WorkFlow counts tokens for \(providerID.displayName) but doesn’t estimate its prices; usage bills to your account. The stop applies only to Amazon Bedrock."
        }
    }

    @ViewBuilder
    private func usageDetails(_ usage: BedrockUsageSummary) -> some View {
        SettingsDivider()
        valueRow("Cleaned", "\(usage.cleanedDictations)")
        SettingsDivider()
        valueRow("Kept the original transcript", "\(usage.fallbackDictations)",
                 detail: "Cleanup didn’t finish, or the stop was reached.")
        if usage.localCleanedDictations > 0 {
            SettingsDivider()
            valueRow("Cleaned on this Mac", "\(usage.localCleanedDictations)")
        }
        if usage.filterDraftRequests > 0 {
            SettingsDivider()
            valueRow("Filter drafts", "\(usage.filterDraftRequests)")
        }
        SettingsDivider()
        valueRow("Tokens", "\(usage.inputTokens) in · \(usage.outputTokens) out")
        if usage.unpricedDictations > 0 {
            SettingsDivider()
            SettingsNotice(
                title: "\(countLabel(usage.unpricedDictations, singular: "request", plural: "requests")) without a price",
                detail: "They used a provider or model WorkFlow can’t price, so they aren’t in the total."
            ) { EmptyView() }
        }
        SettingsDivider()
        efficiencyRows
    }

    private func valueRow(_ title: String, _ value: String, detail: String? = nil) -> some View {
        SettingsRow(title: title, detail: detail) {
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var efficiencyRows: some View {
        let summary = viewModel.tokenEfficiencySummary
        return VStack(alignment: .leading, spacing: 8) {
            Text("Writing efficiency")
                .font(.system(size: 13))
            Text("Estimated source tokens ÷ final tokens for successful cleanups, measured on this Mac (\(LocalTokenEstimator.identifier)), not provider billing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(CleanupMode.allCases) { mode in
                HStack {
                    Text(mode.displayName)
                        .font(.callout)
                    Spacer()
                    if let metric = summary[mode] {
                        Text("\(TokenEfficiencyFormatter.ratio(metric.geometricMeanRatio)) · \(countLabel(metric.sampleCount, singular: "sample", plural: "samples"))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No samples yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            ForEach([CleanupMode.homework, .everyday], id: \.self) { mode in
                if let comparison = technicalComparison(over: mode) {
                    Label(comparison, systemImage: "chart.bar.xaxis")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ThemePalette.linkText(colorScheme))
                }
            }
        }
        .settingsRowPadding()
    }

    private func technicalComparison(over mode: CleanupMode) -> String? {
        guard let advantage = viewModel.tokenEfficiencySummary.advantage(of: .technical, over: mode),
              advantage > 0 else { return nil }
        if advantage >= 1 {
            return String(format: "Technical is %.2f× as token-efficient as %@", advantage, mode.displayName)
        }
        return String(format: "%@ is %.2f× as token-efficient as Technical", mode.displayName, 1 / advantage)
    }

    // MARK: Connection test

    @MainActor
    private func testProvider() async {
        isTesting = true
        defer { isTesting = false }
        let account: CleanupCredentialAccount? = switch providerID {
        case .openAICompatible: .openAICompatible
        case .azureOpenAI: .azureOpenAI
        case .bedrock, .ollama: nil
        }
        let enteredKey = (providerID == .azureOpenAI ? azureAPIKey : compatibleAPIKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let provider: OpenAIChatCleanupService
            switch providerID {
            case .ollama:
                provider = OpenAIChatCleanupService(
                    providerID: .ollama,
                    baseURL: ollamaBaseURL,
                    modelID: ollamaModelID,
                    apiKey: nil,
                    timeout: ollamaTimeout
                )
            case .openAICompatible:
                let stored = try CleanupCredentialStore.loadAPIKey(for: .openAICompatible)
                let key = enteredKey.isEmpty ? stored : enteredKey
                guard (key?.isEmpty == false) || OpenAIChatCleanupService.isLocalBaseURL(compatibleBaseURL) else {
                    providerStatus = "Enter an API key first."
                    return
                }
                provider = OpenAIChatCleanupService(
                    providerID: .openAICompatible,
                    baseURL: compatibleBaseURL,
                    modelID: compatibleModelID,
                    apiKey: key,
                    timeout: compatibleTimeout
                )
            case .azureOpenAI:
                let stored = try CleanupCredentialStore.loadAPIKey(for: .azureOpenAI)
                let key = enteredKey.isEmpty ? stored : enteredKey
                guard key?.isEmpty == false else {
                    providerStatus = "Enter an API key first."
                    return
                }
                provider = OpenAIChatCleanupService(
                    providerID: .azureOpenAI,
                    baseURL: azureEndpoint,
                    modelID: azureDeployment,
                    apiKey: key,
                    timeout: azureTimeout,
                    usesReasoningParameters: azureReasoningDeployment
                )
            case .bedrock:
                return
            }

            let result = try await provider.clean(
                transcript: "Um, this is a \(AppIdentity.productName) connection test.",
                systemPrompt: CleanupPromptBuilder.baseSystemPrompt
            )
            if let account, !enteredKey.isEmpty {
                do {
                    try CleanupCredentialStore.saveAPIKey(enteredKey, for: account)
                    setKeyState(stored: true, for: account)
                } catch {
                    providerStatus = "Connected, but the key could not be saved: \(error.localizedDescription)"
                    return
                }
            }
            let tokenCount = (result.inputTokens ?? 0) + (result.outputTokens ?? 0)
            providerStatus = tokenCount > 0 ? "Connected · \(tokenCount) tokens for this test." : "Connected successfully."
        } catch {
            if account != nil, !enteredKey.isEmpty {
                providerStatus = "Connection failed; the new key was not saved: \(error.localizedDescription)"
            } else {
                providerStatus = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    private func removeKey(for provider: CleanupProviderID) {
        switch provider {
        case .bedrock:
            viewModel.clearBedrockCredential()
        case .openAICompatible, .azureOpenAI:
            let account: CleanupCredentialAccount = provider == .azureOpenAI ? .azureOpenAI : .openAICompatible
            do {
                try CleanupCredentialStore.deleteAPIKey(for: account)
                setKeyState(stored: false, for: account)
                providerStatus = "API key removed from Keychain."
            } catch {
                providerStatus = error.localizedDescription
            }
        case .ollama:
            break
        }
    }

    /// Clears the entry field and records whether a key is stored.
    private func setKeyState(stored: Bool, for account: CleanupCredentialAccount) {
        switch account {
        case .openAICompatible:
            compatibleAPIKey = ""
            viewModel.hasCompatibleAPIKey = stored
        case .azureOpenAI:
            azureAPIKey = ""
            viewModel.hasAzureAPIKey = stored
        }
    }
}

// MARK: - Personalize

/// Teach WorkFlow your style: learning from finished writing, personal
/// vocabulary, rules for particular apps, and a backup of both.
struct PersonalizationSettingsView: View {
    private struct RunningApp: Identifiable, Hashable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    private struct Archive: Codable {
        let formatVersion: Int
        let vocabulary: [VocabularyEntry]
        let appRules: [TargetAppRule]
    }

    let learningSession: CorrectionLearningSession?

    @State private var vocabulary = VocabularyStore.load()
    @State private var rules = TargetAppRuleStore.load()
    @State private var runningApps: [RunningApp] = []
    @State private var selectedBundleID = ""
    @State private var archiveStatus = ""

    init(learningSession: CorrectionLearningSession? = nil) {
        self.learningSession = learningSession
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPaneHeader(
                title: "Personalize",
                subtitle: "Teach WorkFlow how you write and the words you use."
            )
            CorrectionLearningCard(session: learningSession)
                .padding(16)
                .settingsSurface()
            vocabularyGroup
            appRulesGroup
            backupGroup
        }
        .onAppear { refreshRunningApps() }
        .onChange(of: vocabulary) { _, value in VocabularyStore.save(value) }
        .onChange(of: rules) { _, value in TargetAppRuleStore.save(value) }
    }

    private var vocabularyGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Personal vocabulary")
                        .font(.headline)
                    Text("Fix names, products, and terms the recognizer gets wrong. Whole phrases only, applied on this Mac before cleanup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("\(vocabulary.count) of \(VocabularyStore.maximumEntries)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Button {
                    vocabulary.append(VocabularyEntry(spoken: "", replacement: ""))
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(vocabulary.count >= VocabularyStore.maximumEntries)
                .accessibilityLabel("Add a vocabulary replacement")
            }

            if vocabulary.isEmpty {
                Text("For example, heard as “fable orchestrator” → write as “Fable Orchestrator”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: WFSpace.sm) {
                    Color.clear.frame(width: 32, height: 1)
                    Text("Heard as").frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 14, height: 1)
                    Text("Write as").frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 18, height: 1)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }

            ForEach(Array($vocabulary.enumerated()), id: \.element.id) { index, $entry in
                let name = Self.accessibilityName(index: index, entry: entry)
                HStack(spacing: WFSpace.sm) {
                    Toggle("", isOn: $entry.isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .frame(width: 32)
                        .accessibilityLabel("Use \(name)")
                    TextField("What speech recognition writes", text: $entry.spoken)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Heard as, \(name)")
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    TextField("Preferred spelling", text: $entry.replacement)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Write as, \(name)")
                    Button(role: .destructive) {
                        vocabulary.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 18)
                    .help("Delete this replacement")
                    .accessibilityLabel("Delete \(name)")
                }
            }
        }
        .padding(16)
        .settingsSurface()
    }

    /// What VoiceOver calls a vocabulary row, even before its fields are filled.
    static func accessibilityName(index: Int, entry: VocabularyEntry) -> String {
        entry.spoken.isEmpty && entry.replacement.isEmpty
            ? "replacement \(index + 1)"
            : "replacement from \(entry.spoken) to \(entry.replacement)"
    }

    private var appRulesGroup: some View {
        SettingsGroup(
            title: "Per-app rules",
            footer: "A rule applies to the app that was in front when recording began."
        ) {
            SettingsRow(title: "Add an app", detail: "Change cleanup, pasting, or style for one app.") {
                HStack(spacing: WFSpace.sm) {
                    Picker("Running app", selection: $selectedBundleID) {
                        Text("Choose a running app").tag("")
                        ForEach(runningApps) { app in
                            Text(app.name).tag(app.bundleID)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    Button("Add") { addSelectedApp() }
                        .disabled(selectedBundleID.isEmpty || rules.contains { $0.bundleID == selectedBundleID })
                        .accessibilityLabel("Add a rule for the chosen app")
                    Button {
                        refreshRunningApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh running apps")
                    .accessibilityLabel("Refresh running apps")
                }
            }
            ForEach($rules) { $rule in
                SettingsDivider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(rule.appName)
                            .font(.system(size: 13, weight: .semibold))
                        Text(rule.bundleID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            rules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete this rule")
                        .accessibilityLabel("Delete the rule for \(rule.appName)")
                    }
                    HStack {
                        Picker("Cleanup", selection: $rule.cleanupBehavior) {
                            ForEach(TargetCleanupBehavior.allCases) { Text($0.displayName).tag($0) }
                        }
                        .fixedSize()
                        Picker("Paste", selection: $rule.pasteBehavior) {
                            ForEach(TargetPasteBehavior.allCases) { Text($0.displayName).tag($0) }
                        }
                        .fixedSize()
                    }
                    TextField("Optional style, e.g. concise Slack message", text: $rule.cleanupInstruction)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Cleanup style for \(rule.appName)")
                }
                .settingsRowPadding()
            }
        }
    }

    private var backupGroup: some View {
        SettingsGroup(
            title: "Backup",
            footer: "Vocabulary and per-app rules as JSON. API keys are never included."
        ) {
            SettingsRow(title: "Personalization file", detail: archiveStatus.isEmpty ? nil : archiveStatus) {
                HStack(spacing: WFSpace.sm) {
                    Button("Export…") { exportArchive() }
                    Button("Import…") { importArchive() }
                }
                .controlSize(.small)
            }
        }
    }

    private func refreshRunningApps() {
        var seen = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier,
                  let name = app.localizedName,
                  bundleID != Bundle.main.bundleIdentifier,
                  seen.insert(bundleID).inserted else { return nil }
            return RunningApp(bundleID: bundleID, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addSelectedApp() {
        guard let app = runningApps.first(where: { $0.bundleID == selectedBundleID }) else { return }
        rules.append(TargetAppRule(bundleID: app.bundleID, appName: app.name))
        selectedBundleID = ""
    }

    private func exportArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "WorkFlow-personalization.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = Archive(formatVersion: 1, vocabulary: vocabulary, appRules: rules)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(archive).write(to: url, options: .atomic)
            archiveStatus = "Exported."
        } catch {
            archiveStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            guard archive.formatVersion == 1 else {
                archiveStatus = "Unsupported file version."
                return
            }
            vocabulary = Array(archive.vocabulary.prefix(VocabularyStore.maximumEntries))
            rules = TargetAppRuleStore.sanitized(archive.appRules)
            archiveStatus = "Imported."
        } catch {
            archiveStatus = "Import failed: \(error.localizedDescription)"
        }
    }
}
