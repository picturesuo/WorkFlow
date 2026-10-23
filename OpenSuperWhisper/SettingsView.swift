import SwiftUI

/// The four places a setting can live. Dictation holds the few things
/// everyone sets once; Cleanup and Personalize are the product; Provider &
/// Cost keeps connection and spending in one place.
enum SettingsPane: String, CaseIterable, Identifiable {
    case dictation
    case cleanup
    case personalize
    case providerCost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .cleanup: "Cleanup"
        case .personalize: "Personalize"
        case .providerCost: "Provider & Cost"
        }
    }

    var symbol: String {
        switch self {
        case .dictation: "mic"
        case .cleanup: "wand.and.stars"
        case .personalize: "person.crop.circle"
        case .providerCost: "dollarsign.circle"
        }
    }
}

/// The one route into Settings: Cmd+, the menu bar, and the dock's
/// Learn link all ask for Settings here.
@MainActor
enum SettingsRequest {
    struct Request: Equatable {
        /// Nil reopens the pane the person last viewed.
        let pane: SettingsPane?
    }

    /// Waits until a main window shows it, so a request made before that
    /// window exists (a menu-bar-only launch) is not lost.
    private static var pending: Request?

    static func open(pane: SettingsPane? = nil) {
        pending = Request(pane: pane)
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    /// Hands the waiting request to one window.
    static func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}

/// Presents Settings on the requested pane, or on the last one viewed.
struct OpenSettingsRequests: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var pane: SettingsPane

    func body(content: Content) -> some View {
        content
            .onAppear(perform: presentPendingRequest)
            .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in presentPendingRequest() }
    }

    private func presentPendingRequest() {
        guard let request = SettingsRequest.take() else { return }
        if let requested = request.pane { pane = requested }
        isPresented = true
    }
}

struct SettingsView: View {
    @StateObject private var viewModel: SettingsViewModel
    @StateObject private var permissionsManager = PermissionsManager()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Binding private var selection: SettingsPane
    /// Lives as long as the sheet, so a pasted document survives a pane switch.
    @StateObject private var learningSession = CorrectionLearningSession(
        mode: CustomCleanupFilterStore.currentSnapshot().mode
    )
    @State private var previousModelURL: URL?
    private let fixedSize: CGSize?

    init(
        selection: Binding<SettingsPane>,
        credentials: StoredCredentialStatus = .keychain,
        size: CGSize? = nil
    ) {
        _selection = selection
        _viewModel = StateObject(wrappedValue: SettingsViewModel(credentials: credentials))
        fixedSize = size
    }

    private var sheetSize: CGSize {
        if let fixedSize { return fixedSize }
        let visibleFrame = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let width = min(720, visibleFrame.width - 40)
        let height = min(660, visibleFrame.height - 60)
        return CGSize(width: width, height: height)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPaneBar(selection: $selection)
                .padding(.top, WFSpace.md)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
            hairline
            ScrollView {
                pane
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
            }
            .id(selection)
            hairline
            footer
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(ThemePalette.windowBackground(colorScheme))
        .tint(ThemePalette.controlTint)
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
            if viewModel.selectedEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.selectedEngine) { _, newEngine in
            if newEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.fluidAudioModelVersion) { _, _ in
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
        .onChange(of: viewModel.selectedModelURL) { _, newURL in
            if viewModel.selectedEngine == "whisper", let modelPath = newURL?.path {
                Task { @MainActor in
                    TranscriptionService.shared.reloadModel(with: modelPath)
                }
            }
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch selection {
        case .dictation:
            DictationSettingsView(viewModel: viewModel, permissionsManager: permissionsManager)
        case .cleanup:
            CleanupSettingsView(viewModel: viewModel) { selection = .providerCost }
        case .personalize:
            PersonalizationSettingsView(learningSession: learningSession)
        case .providerCost:
            ProviderCostSettingsView(viewModel: viewModel) { selection = .cleanup }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(ThemePalette.hairline(colorScheme))
            .frame(height: 1)
    }

    private var footer: some View {
        HStack {
            Link(destination: URL(string: "https://github.com/picturesuo/WorkFlow")!) {
                Label("WorkFlow on GitHub", systemImage: "star")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Spacer()
            Button("Done") {
                if viewModel.selectedEngine == "whisper" {
                    if viewModel.selectedModelURL != previousModelURL, let modelPath = viewModel.selectedModelURL?.path {
                        TranscriptionService.shared.reloadModel(with: modelPath)
                    }
                }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, WFSpace.md)
    }
}
