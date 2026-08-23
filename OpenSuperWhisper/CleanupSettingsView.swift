import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CleanupSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var providerID: CleanupProviderID
    @State private var ollamaBaseURL: String
    @State private var ollamaModelID: String
    @State private var ollamaTimeout: Double
    @State private var compatibleBaseURL: String
    @State private var compatibleModelID: String
    @State private var compatibleTimeout: Double
    @State private var compatibleAPIKey = ""
    @State private var hasCompatibleAPIKey = false
    @State private var providerStatus = ""
    @State private var isTesting = false

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        let prefs = AppPreferences.shared
        _providerID = State(initialValue: CleanupProviderID(rawValue: prefs.cleanupProviderID) ?? .bedrock)
        _ollamaBaseURL = State(initialValue: prefs.ollamaBaseURL)
        _ollamaModelID = State(initialValue: prefs.ollamaModelID)
        _ollamaTimeout = State(initialValue: prefs.ollamaTimeoutSeconds)
        _compatibleBaseURL = State(initialValue: prefs.openAICompatibleBaseURL)
        _compatibleModelID = State(initialValue: prefs.openAICompatibleModelID)
        _compatibleTimeout = State(initialValue: prefs.openAICompatibleTimeoutSeconds)
        _hasCompatibleAPIKey = State(initialValue: ((try? CleanupCredentialStore.loadAPIKey()) ?? nil) != nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                overviewCard
                providerCard
                usageCard
                if let lastError = viewModel.bedrockLastErrorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Last cleanup used the local fallback", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.orange)
                        Text(lastError)
                            .font(.caption)
                            .textSelection(.enabled)
                        if let date = viewModel.bedrockLastErrorDate {
                            Text(date, style: .relative)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .settingsCard()
                }
                privacyCard
            }
            .padding()
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
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI transcript cleanup")
                        .font(.headline)
                    Text("Speech recognition and audio stay on your Mac. Cleanup sends only transcript text to the provider you select.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $viewModel.bedrockCleanupEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Enable AI transcript cleanup")
                    .accessibilityValue(viewModel.bedrockCleanupEnabled ? "On" : "Off")
            }

            Picker("Cleanup provider", selection: $providerID) {
                ForEach(CleanupProviderID.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.bedrockCleanupEnabled)
        }
        .settingsCard()
    }

    @ViewBuilder
    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch providerID {
            case .bedrock:
                bedrockFields
            case .ollama:
                ollamaFields
            case .openAICompatible:
                compatibleFields
            }

            if !currentStatus.isEmpty {
                Text(currentStatus)
                    .font(.caption)
                    .foregroundColor(currentStatus.localizedCaseInsensitiveContains("failed") ? .orange : .secondary)
                    .textSelection(.enabled)
            }
        }
        .settingsCard()
    }

    private var bedrockFields: some View {
        Group {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Amazon Bedrock")
                        .font(.headline)
                    Text("Best fit for your AWS credits. Nova Micro is the recommended low-cost model.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Link("Create API key", destination: URL(string: "https://console.aws.amazon.com/bedrock/home#/api-keys")!)
                    .font(.caption)
            }

            SecureField(
                viewModel.hasBedrockAPIKey ? "Stored in Keychain (enter to replace)" : "Bedrock API key",
                text: $viewModel.bedrockAPIKeyInput
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Amazon Bedrock API key")
            .accessibilityHint("Stored securely in macOS Keychain after a successful connection test")

            LabeledContent("AWS region") {
                TextField("us-east-1", text: $viewModel.bedrockRegion)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            LabeledContent("Model ID") {
                TextField("Model ID", text: $viewModel.bedrockModelID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }
            timeoutRow(value: $viewModel.bedrockTimeoutSeconds, range: 0.5...20)

            HStack {
                Toggle("Monthly estimated-cost stop", isOn: $viewModel.bedrockMonthlyBudgetEnabled)
                    .accessibilityHint("For models with verified pricing, uses local text after the monthly estimate reaches the limit")
                Spacer()
                if viewModel.bedrockMonthlyBudgetEnabled {
                    Stepper(
                        BedrockPricing.formatUSD(viewModel.bedrockMonthlyBudgetUSD),
                        value: $viewModel.bedrockMonthlyBudgetUSD,
                        in: 0.05...10,
                        step: 0.05
                    )
                    .frame(width: 150)
                    .accessibilityLabel("Monthly Bedrock estimated-cost stop")
                    .accessibilityValue(BedrockPricing.formatUSD(viewModel.bedrockMonthlyBudgetUSD))
                }
            }

            if !BedrockPricing.supports(modelID: viewModel.bedrockModelID) {
                Text("This model has no verified price in WorkFlow, so the monthly stop cannot be enforced. Use Recommended defaults for a bounded estimate.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                Button {
                    Task { await viewModel.saveAndTestBedrock() }
                } label: {
                    testLabel(active: viewModel.isTestingBedrock, title: "Save & Test")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isTestingBedrock)
                .accessibilityLabel(viewModel.isTestingBedrock ? "Testing Amazon Bedrock connection" : "Save API key and test Amazon Bedrock")

                Button("Recommended defaults") { viewModel.useRecommendedBedrockDefaults() }
                if viewModel.hasBedrockAPIKey {
                    Button("Remove key", role: .destructive) { viewModel.clearBedrockCredential() }
                }
            }
        }
    }

    private var ollamaFields: some View {
        Group {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ollama on this Mac")
                        .font(.headline)
                    Text("No account, API key, or per-token bill. The transcript never leaves this Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Link("Get Ollama", destination: URL(string: "https://ollama.com/download/mac")!)
                    .font(.caption)
            }

            Text("Install Ollama, then run `ollama pull \(ollamaModelID)` once in Terminal.")
                .font(.caption.monospaced())
                .textSelection(.enabled)

            LabeledContent("Server") {
                TextField("http://localhost:11434", text: $ollamaBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }
            LabeledContent("Model") {
                TextField("llama3.2:3b", text: $ollamaModelID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }
            timeoutRow(value: $ollamaTimeout, range: 1...60)

            Button {
                Task { await testProvider() }
            } label: {
                testLabel(active: isTesting, title: "Test local Ollama")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isTesting)
        }
    }

    private var compatibleFields: some View {
        Group {
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenAI-compatible API")
                    .font(.headline)
                Text("Connect OpenAI, OpenRouter, LM Studio, Together, or another service that implements chat completions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            LabeledContent("Base URL") {
                TextField("https://api.example.com/v1", text: $compatibleBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }
            LabeledContent("Model") {
                TextField("Provider model ID", text: $compatibleModelID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }
            SecureField(
                hasCompatibleAPIKey ? "Stored in Keychain (enter to replace)" : "API key",
                text: $compatibleAPIKey
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("OpenAI-compatible API key")
            .accessibilityHint("Stored securely in macOS Keychain after a successful connection test")
            timeoutRow(value: $compatibleTimeout, range: 1...60)

            HStack {
                Button {
                    Task { await testProvider() }
                } label: {
                    testLabel(active: isTesting, title: "Save & Test")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting)

                if hasCompatibleAPIKey {
                    Button("Remove key", role: .destructive) { removeCompatibleKey() }
                }
            }

            Text("Pricing depends on the service and model. \(AppIdentity.productName) records token counts but does not invent a dollar estimate when provider pricing is unknown.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var usageCard: some View {
        let usage = viewModel.bedrockUsageSummary
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This month")
                        .font(.headline)
                    Text("Recorded cleanup usage across every provider")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(BedrockPricing.formatUSD(usage.estimatedCostUSD))
                    .font(.title2.weight(.semibold).monospacedDigit())
            }
            Text("\(usage.cleanedDictations) cleaned · \(usage.localCleanedDictations) free local · \(usage.fallbackDictations) fallbacks · \(usage.inputTokens) input / \(usage.outputTokens) output tokens")
                .font(.caption)
                .foregroundColor(.secondary)
            if usage.unpricedDictations > 0 {
                Text("\(usage.unpricedDictations) request(s) used custom or unknown pricing and are excluded from the dollar total.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Text("Nova Micro example: 100 short dictations/day is roughly $0.04/month at the checked AWS price. Ollama API cost is $0; electricity and hardware are yours.")
                .font(.caption)
                .foregroundColor(.secondary)
            if viewModel.bedrockMonthlyBudgetEnabled {
                let remaining = max(0, viewModel.bedrockMonthlyBudgetUSD - usage.estimatedCostUSD)
                Text("Bedrock limit: \(BedrockPricing.formatUSD(viewModel.bedrockMonthlyBudgetUSD)) · \(BedrockPricing.formatUSD(remaining)) estimated remaining")
                    .font(.caption.weight(.medium))
                    .foregroundColor(remaining > 0 ? .secondary : .orange)
            }
            Link("AWS pricing · checked \(BedrockPricing.asOfDate)", destination: BedrockPricing.pricingURL)
                .font(.caption)
        }
        .settingsCard()
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Fail-safe by design", systemImage: "lock.shield")
                .font(.headline)
            Text("Provider keys use macOS Keychain. Remote servers must use HTTPS. If cleanup times out, fails, exceeds its budget, or rewrites too aggressively, \(AppIdentity.productName) keeps the local transcript instead of losing your dictation.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .settingsCard()
    }

    private var currentStatus: String {
        providerID == .bedrock ? viewModel.bedrockStatus : providerStatus
    }

    private func timeoutRow(value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text("Fallback timeout")
            Spacer()
            Stepper("\(value.wrappedValue, specifier: "%.1f") seconds", value: value, in: range, step: 0.5)
                .frame(width: 190)
        }
    }

    @ViewBuilder
    private func testLabel(active: Bool, title: String) -> some View {
        if active {
            ProgressView().controlSize(.small)
        } else {
            Label(title, systemImage: "checkmark.shield")
        }
    }

    @MainActor
    private func testProvider() async {
        isTesting = true
        defer { isTesting = false }
        let enteredCompatibleKey = compatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
                let stored = try CleanupCredentialStore.loadAPIKey()
                let key = enteredCompatibleKey.isEmpty ? stored : enteredCompatibleKey
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
            case .bedrock:
                return
            }

            let result = try await provider.clean(
                transcript: "Um, this is a \(AppIdentity.productName) connection test.",
                systemPrompt: CleanupPromptBuilder.baseSystemPrompt
            )
            if providerID == .openAICompatible, !enteredCompatibleKey.isEmpty {
                do {
                    try CleanupCredentialStore.saveAPIKey(enteredCompatibleKey)
                    compatibleAPIKey = ""
                    hasCompatibleAPIKey = true
                } catch {
                    providerStatus = "Connected, but the key could not be saved: \(error.localizedDescription)"
                    return
                }
            }
            let tokenCount = (result.inputTokens ?? 0) + (result.outputTokens ?? 0)
            providerStatus = tokenCount > 0 ? "Connected · \(tokenCount) tokens for this test." : "Connected successfully."
        } catch {
            if providerID == .openAICompatible, !enteredCompatibleKey.isEmpty {
                providerStatus = "Connection failed; the new key was not saved: \(error.localizedDescription)"
            } else {
                providerStatus = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    private func removeCompatibleKey() {
        do {
            try CleanupCredentialStore.deleteAPIKey()
            compatibleAPIKey = ""
            hasCompatibleAPIKey = false
            providerStatus = "API key removed from Keychain."
        } catch {
            providerStatus = error.localizedDescription
        }
    }
}

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

    @State private var vocabulary = VocabularyStore.load()
    @State private var rules = TargetAppRuleStore.load()
    @State private var runningApps: [RunningApp] = []
    @State private var selectedBundleID = ""
    @State private var meetingCleanupEnabled = AppPreferences.shared.meetingCleanupEnabled
    @State private var archiveStatus = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                vocabularyCard
                appRulesCard
                meetingsCard
                backupCard
            }
            .padding()
        }
        .onAppear { refreshRunningApps() }
        .onChange(of: vocabulary) { _, value in VocabularyStore.save(value) }
        .onChange(of: rules) { _, value in TargetAppRuleStore.save(value) }
        .onChange(of: meetingCleanupEnabled) { _, value in AppPreferences.shared.meetingCleanupEnabled = value }
    }

    private var vocabularyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Personal vocabulary")
                        .font(.headline)
                    Text("Correct names, products, and technical terms with literal whole-phrase matches.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    vocabulary.append(VocabularyEntry(spoken: "", replacement: ""))
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(vocabulary.count >= VocabularyStore.maximumEntries)
            }

            if vocabulary.isEmpty {
                Text("Example: spoken “fable orchestrator” → spelling “Fable Orchestrator”")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach($vocabulary) { $entry in
                HStack {
                    Toggle("", isOn: $entry.isEnabled)
                        .labelsHidden()
                        .accessibilityLabel("Enable vocabulary replacement from \(entry.spoken) to \(entry.replacement)")
                    TextField("What speech recognition writes", text: $entry.spoken)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)
                    TextField("Preferred spelling", text: $entry.replacement)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        vocabulary.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete vocabulary replacement")
                }
            }
        }
        .settingsCard()
    }

    private var appRulesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Per-app behavior")
                    .font(.headline)
                Text("Choose cleanup and paste behavior by the app that was focused when recording began.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Picker("Running app", selection: $selectedBundleID) {
                    Text("Choose a running app").tag("")
                    ForEach(runningApps) { app in
                        Text("\(app.name) — \(app.bundleID)").tag(app.bundleID)
                    }
                }
                Button("Add app") { addSelectedApp() }
                    .disabled(selectedBundleID.isEmpty || rules.contains { $0.bundleID == selectedBundleID })
                Button {
                    refreshRunningApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh running apps")
                .accessibilityLabel("Refresh running apps")
            }

            ForEach($rules) { $rule in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(rule.appName)
                            .font(.subheadline.weight(.semibold))
                        Text(rule.bundleID)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            rules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    HStack {
                        Picker("Cleanup", selection: $rule.cleanupBehavior) {
                            ForEach(TargetCleanupBehavior.allCases) { Text($0.displayName).tag($0) }
                        }
                        Picker("Paste", selection: $rule.pasteBehavior) {
                            ForEach(TargetPasteBehavior.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                    TextField("Optional cleanup style, e.g. concise Slack message", text: $rule.cleanupInstruction)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .settingsCard()
    }

    private var meetingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Clean up meeting transcripts", isOn: $meetingCleanupEnabled)
                .font(.headline)
            Text("Meeting mode records until you stop it, saves a named item in History, and never pastes into another app. Cleanup is off by default so long transcripts stay local and free.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .settingsCard()
    }

    private var backupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Backup personalization")
                .font(.headline)
            Text("Export or import vocabulary and app rules as JSON. API keys are intentionally never included.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Button("Export JSON") { exportArchive() }
                Button("Import JSON") { importArchive() }
                if !archiveStatus.isEmpty {
                    Text(archiveStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .settingsCard()
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

private extension View {
    func settingsCard() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
