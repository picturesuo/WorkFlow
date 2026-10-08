import SwiftUI

/// Drafts a new filter or improves a saved one from a plain-language request,
/// an optional completed example, and an optional class or assignment.
struct FilterAssistantSheet: View {
    @ObservedObject var session: FilterAssistantSession
    @ObservedObject var voice: FilterAssistantVoiceInput
    let onClose: () -> Void

    @State private var showsExample: Bool

    init(
        session: FilterAssistantSession,
        voice: FilterAssistantVoiceInput,
        showsExample: Bool = false,
        onClose: @escaping () -> Void
    ) {
        self.session = session
        self.voice = voice
        self.onClose = onClose
        _showsExample = State(initialValue: showsExample)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !session.entries.isEmpty {
                conversation
            }
            composer
            if let message = session.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.proposal != nil {
                Divider()
                proposalEditor
            }
            footer
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            voice.onTranscript = { [weak session] text in
                guard let session else { return }
                let current = session.request.trimmingCharacters(in: .whitespacesAndNewlines)
                session.request = current.isEmpty ? text : current + " " + text
            }
        }
        .onDisappear {
            voice.cancel()
            session.cancelGeneration()
        }
    }

    private var title: String {
        if case .existing(let filter) = session.target {
            return "Improve “\(filter.name)” with AI"
        }
        return "Create a filter with AI"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text("Say what to change. Paste a finished assignment if you want the filter to match it. You review everything before it is saved.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                session.destination.isOnThisMac
                    ? "Runs on this Mac with \(session.destination.summary) when you press Send."
                    : "Sends your request, example, and class to \(session.destination.summary) only when you press Send.",
                systemImage: session.destination.isOnThisMac ? "desktopcomputer" : "network"
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var conversation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.entries) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: entry.role == .user ? "person.fill" : "sparkles")
                            .font(.caption)
                            .foregroundColor(entry.role == .user ? .secondary : .accentColor)
                            .frame(width: 14)
                            .accessibilityHidden(true)
                        Text(entry.text)
                            .font(.callout)
                            .foregroundColor(entry.role == .user ? .secondary : .primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(entry.role == .user ? "You" : "Assistant"): \(entry.text)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxHeight: 110)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                boundedEditor(
                    text: $session.request,
                    placeholder: session.proposal == nil
                        ? "e.g. Write numbers as digits, “square root” as √, and “times” as x with a space on each side."
                        : "What should change? e.g. Use × instead of x.",
                    height: 54,
                    accessibilityLabel: "What the filter should change"
                )
                microphoneControl
            }
            TextField("Class or assignment (optional), e.g. Math 21a problem sets", text: $session.context)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Class or assignment, optional")
            DisclosureGroup(isExpanded: $showsExample) {
                VStack(alignment: .leading, spacing: 4) {
                    boundedEditor(
                        text: $session.example,
                        placeholder: "Paste text you finished, written the way you want future dictations to look.",
                        height: 84,
                        accessibilityLabel: "Completed example, optional"
                    )
                    HStack {
                        Text("Used only as a style example. It is not saved.")
                        Spacer()
                        counter(session.example, limit: FilterAssistantPrompt.maximumExampleLength)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            } label: {
                Text(session.example.isEmpty ? "Add a completed example (optional)" : "Completed example")
                    .font(.callout)
            }
            HStack {
                if let voiceError = voice.errorMessage {
                    Text(voiceError)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if voice.state == .idle, voice.isModelLoading {
                    Text("The speech model is loading. You can type meanwhile.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if voice.state == .recording {
                    Label("Listening for the assistant only. Nothing is pasted.", systemImage: "waveform")
                        .font(.caption)
                        .foregroundColor(.red)
                } else if voice.state == .transcribing {
                    Text("Transcribing on this Mac…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if session.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Drafting")
                    Button("Stop") { session.cancelGeneration() }
                        .accessibilityHint("Stops the request; your draft stays unchanged")
                } else {
                    Button {
                        session.send()
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!session.canSend || voice.state != .idle)
                    .help("Send to \(session.destination.summary) (⌘↩)")
                }
            }
        }
    }

    @ViewBuilder
    private var microphoneControl: some View {
        switch voice.state {
        case .idle:
            Button {
                voice.start()
            } label: {
                Image(systemName: "mic")
                    .frame(width: 18, height: 18)
            }
            .disabled(session.isGenerating || voice.isModelLoading)
            .help(voice.isModelLoading ? "The speech model is still loading" : "Speak your request (transcribed on this Mac)")
            .accessibilityLabel("Speak your request")
        case .recording:
            VStack(spacing: 4) {
                Button {
                    voice.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundColor(.red)
                        .frame(width: 18, height: 18)
                }
                .help("Stop and transcribe")
                .accessibilityLabel("Stop recording and transcribe")
                Button {
                    voice.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                }
                .help("Discard recording")
                .accessibilityLabel("Discard recording")
            }
        case .transcribing:
            Button {
                voice.cancel()
            } label: {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            }
            .help("Cancel transcription")
            .accessibilityLabel("Transcribing. Cancel")
        }
    }

    private var proposalEditor: some View {
        let binding = Binding<FilterAssistantProposal>(
            get: { session.proposal ?? FilterAssistantProposal(name: "", baseMode: .everyday, instructions: "") },
            set: { session.proposal = $0 }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Proposed filter")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Edit anything before saving")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            TextField("Filter name", text: binding.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Proposed filter name")
            Picker("Based on", selection: binding.baseMode) {
                ForEach(CleanupMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            boundedEditor(
                text: binding.instructions,
                placeholder: "Style instructions",
                height: 96,
                accessibilityLabel: "Proposed filter instructions"
            )
            HStack {
                Toggle("Use for new dictations", isOn: $session.selectAfterSaving)
                    .toggleStyle(.checkbox)
                Spacer()
                counter(binding.wrappedValue.instructions, limit: CustomCleanupFilterStore.maximumInstructionLength)
                    .font(.caption)
            }
        }
        .disabled(session.isGenerating)
    }

    private var footer: some View {
        HStack {
            if !session.entries.isEmpty || session.proposal != nil {
                Button("Start over") { session.startOver() }
                    .disabled(session.isGenerating)
            }
            Spacer()
            Button("Close") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button(session.saveTitle) {
                if session.save() != nil { onClose() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.proposal == nil || session.isGenerating)
        }
    }

    private func boundedEditor(
        text: Binding<String>,
        placeholder: String,
        height: CGFloat,
        accessibilityLabel: String
    ) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.callout)
                .frame(height: height)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .accessibilityLabel(accessibilityLabel)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func counter(_ value: String, limit: Int) -> some View {
        let count = value.trimmingCharacters(in: .whitespacesAndNewlines).count
        return Text("\(count)/\(limit)")
            .monospacedDigit()
            .foregroundColor(count > limit ? .orange : .secondary)
    }
}
