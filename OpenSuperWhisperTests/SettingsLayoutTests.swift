import AppKit
import SwiftUI
import XCTest
@testable import OpenSuperWhisper

/// Renders the real Settings sheet offscreen, pane by pane. Credentials come
/// from a stub, so nothing reads Keychain; preferences live in the test
/// host's own domain and are restored afterwards; History is in memory.
@MainActor
final class SettingsLayoutTests: XCTestCase {
    /// Non-default values for every preference the panes show.
    private static let seeded: [String: Any] = [
        "selectedEngine": "fluidaudio",
        "fluidAudioModelVersion": "v3",
        "whisperLanguage": "fr",
        "modifierOnlyHotkey": ModifierKey.rightOption.rawValue,
        "secondaryModifierOnlyHotkey": ModifierKey.leftControl.rawValue,
        "mouseButtonHotkey": MouseButton.none.rawValue,
        "holdToRecord": false,
        "doublePressToTrigger": true,
        "autoCopyToClipboard": false,
        "autoPasteTranscription": true,
        "addSpaceAfterSentence": false,
        "playSoundOnRecordStart": true,
        "ignoreEscWhileRecording": true,
        "escCancelWithoutConfirmation": true,
        "launchAtLogin": false,
        "startHiddenInMenuBar": false,
        "bedrockCleanupEnabled": true,
        "cleanupProviderID": CleanupProviderID.bedrock.rawValue,
        "bedrockRegion": "us-west-2",
        "bedrockModelID": "us.amazon.nova-micro-v1:0",
        "bedrockTimeoutSeconds": 4.5,
        "bedrockMonthlyBudgetEnabled": true,
        "bedrockMonthlyBudgetUSD": 0.5,
        "ollamaBaseURL": "http://localhost:22434",
        "ollamaModelID": "fixture-model:1b",
        "openAICompatibleBaseURL": "https://fixture.example/v1",
        "openAICompatibleModelID": "fixture-compatible",
        "azureOpenAIEndpoint": "https://fixture.openai.azure.com",
        "azureOpenAIDeployment": "fixture-deployment",
        "azureOpenAIReasoningDeployment": true,
        "meetingCleanupEnabled": true,
        "suppressBlankAudio": false,
        "showTimestamps": true,
        "temperature": 0.3,
        "noSpeechThreshold": 0.4,
        "initialPrompt": "Fixture prompt",
        "useBeamSearch": true,
        "beamSize": 3,
        "autoDeleteRecordingsEnabled": false,
        "autoDeleteRecordingsAfterDays": 14,
        "personalVocabularyData": try! JSONEncoder().encode([VocabularyEntry(spoken: "fable orchestrator", replacement: "Fable Orchestrator")]),
    ]
    private static let cleared = ["bedrockLastErrorMessage", "bedrockLastErrorDate", "debugMode", "modifierChordHotkey"]

    private var originals: [String: Any?] = [:]
    private var appStorage: UserDefaults!
    private var appStorageSuite: String!

    override func setUp() {
        super.setUp()
        let standard = UserDefaults.standard
        for key in Array(Self.seeded.keys) + Self.cleared + [CustomCleanupFilterStore.dataKey, CustomCleanupFilterStore.selectedIDKey, CustomCleanupFilterStore.modeKey] {
            originals[key] = standard.object(forKey: key)
        }
        for (key, value) in Self.seeded { standard.set(value, forKey: key) }
        for key in Self.cleared { standard.removeObject(forKey: key) }
        appStorageSuite = "SettingsLayoutTests-\(UUID().uuidString)"
        appStorage = UserDefaults(suiteName: appStorageSuite)
        let digits = CustomCleanupFilterStore.examples[0]
        CustomCleanupFilterStore.save([digits, CustomCleanupFilterStore.examples[2]], to: appStorage)
        CustomCleanupFilterStore.select(.builtIn(.writing), in: appStorage)
    }

    override func tearDown() {
        let standard = UserDefaults.standard
        for (key, value) in originals {
            if let value { standard.set(value, forKey: key) } else { standard.removeObject(forKey: key) }
        }
        appStorage.removePersistentDomain(forName: appStorageSuite)
        super.tearDown()
    }

    private func stub(bedrockStored: Bool = true, calls: Counter? = nil) -> StoredCredentialStatus {
        StoredCredentialStatus(
            bedrock: { calls?.bedrock += 1; return bedrockStored },
            cleanup: { _ in calls?.cleanup += 1; return false }
        )
    }

    final class Counter {
        var bedrock = 0
        var cleanup = 0
    }

    // MARK: Layout

    func testEveryPaneRendersAtCompactAndWideSizesInLightAndDark() throws {
        for pane in SettingsPane.allCases {
            for size in [CGSize(width: 600, height: 560), CGSize(width: 760, height: 680)] {
                for scheme in [ColorScheme.light, .dark] {
                    let bitmap = try render(
                        SettingsView(selection: .constant(pane), credentials: stub(), size: size),
                        size: size,
                        scheme: scheme,
                        name: "settings-\(pane.rawValue)-\(Int(size.width))"
                    )
                    XCTAssertEqual(purplePixels(in: bitmap), 0, "\(pane) \(Int(size.width)) \(scheme)")
                }
            }
        }
    }

    /// Whole panes, scrolled out to full height, for visual review.
    func testFullPaneContentForReview() throws {
        let heights: [SettingsPane: CGFloat] = [.dictation: 1000, .cleanup: 1500, .personalize: 1250, .providerCost: 1350]
        for pane in SettingsPane.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let size = CGSize(width: 720, height: heights[pane] ?? 1200)
                try render(
                    SettingsView(selection: .constant(pane), credentials: stub(), size: size),
                    size: size,
                    scheme: scheme,
                    name: "settings-full-\(pane.rawValue)"
                )
            }
        }
    }

    // MARK: Keyboard and VoiceOver

    func testVocabularyRowsKeepAVoiceOverNameWhenEmpty() {
        XCTAssertEqual(PersonalizationSettingsView.accessibilityName(index: 0, entry: VocabularyEntry(spoken: "", replacement: "")),
                       "replacement 1")
        XCTAssertEqual(PersonalizationSettingsView.accessibilityName(index: 2, entry: VocabularyEntry(spoken: "note book", replacement: "notebook")),
                       "replacement from note book to notebook")
    }

    func testCommandNumberSwitchesPanes() throws {
        final class Selection: ObservableObject { @Published var pane = SettingsPane.dictation }
        struct Host: View {
            @ObservedObject var selection: Selection
            let credentials: StoredCredentialStatus
            var body: some View {
                SettingsView(selection: $selection.pane, credentials: credentials, size: CGSize(width: 720, height: 660))
            }
        }
        let selection = Selection()
        let host = try hostedView(Host(selection: selection, credentials: stub()), size: CGSize(width: 720, height: 660))
        for (index, pane) in SettingsPane.allCases.enumerated().reversed() {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: host.window?.windowNumber ?? 0, context: nil,
                characters: "\(index + 1)", charactersIgnoringModifiers: "\(index + 1)", isARepeat: false, keyCode: 0
            ))
            XCTAssertTrue(host.window?.performKeyEquivalent(with: event) ?? false, "⌘\(index + 1) is handled")
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(selection.pane, pane)
        }
    }

    // MARK: Credentials and preferences

    func testOpeningSettingsAsksTheCredentialSeamOnceAndNeverReadsKeys() throws {
        let calls = Counter()
        let size = CGSize(width: 720, height: 660)
        for pane in SettingsPane.allCases {
            try render(SettingsView(selection: .constant(pane), credentials: stub(calls: calls), size: size),
                       size: size, scheme: .light, name: nil)
        }
        XCTAssertEqual(calls.bedrock, SettingsPane.allCases.count, "One Bedrock presence check per sheet")
        XCTAssertEqual(calls.cleanup, 2 * SettingsPane.allCases.count, "One check each for the compatible and Azure accounts")

        let model = SettingsViewModel(credentials: stub(bedrockStored: false))
        XCTAssertFalse(model.hasBedrockAPIKey)
        XCTAssertEqual(model.bedrockAPIKeyInput, "", "Settings never fills the secure field")
        let failing = StoredCredentialStatus(bedrock: { throw BedrockCredentialStoreError.keychain(-25300) }, cleanup: { _ in false })
        XCTAssertFalse(SettingsViewModel(credentials: failing).bedrockStatus.isEmpty, "A Keychain error is reported, not hidden")
    }

    func testOpeningEveryPaneLeavesEveryPreferenceAsItWas() throws {
        let size = CGSize(width: 720, height: 1400)
        for pane in SettingsPane.allCases {
            for scheme in [ColorScheme.light, .dark] {
                try render(SettingsView(selection: .constant(pane), credentials: stub(), size: size),
                           size: size, scheme: scheme, name: nil)
            }
        }
        let standard = UserDefaults.standard
        for (key, value) in Self.seeded {
            XCTAssertEqual(standard.object(forKey: key) as? NSObject, value as? NSObject, "\(key) changed on appear")
        }
        XCTAssertNil(standard.object(forKey: "debugMode"), "The removed debug switch writes nothing")
        XCTAssertNil(standard.object(forKey: "modifierChordHotkey"), "The shortcut picker writes nothing until chosen")
        XCTAssertEqual(CustomCleanupFilterStore.load(from: appStorage).count, 2, "Saved filters are untouched")
        XCTAssertEqual(CustomCleanupFilterStore.currentSelection(in: appStorage), .builtIn(.writing))
    }

    func testBasicControlsWriteThroughToTheirExistingPreferences() {
        let model = SettingsViewModel(credentials: stub())
        XCTAssertEqual(model.modifierOnlyHotkey, .rightOption)
        XCTAssertEqual(model.secondaryModifierOnlyHotkey, .leftControl)
        XCTAssertFalse(model.holdToRecord)
        XCTAssertEqual(model.selectedLanguage, "fr")

        model.holdToRecord = true
        model.secondaryModifierOnlyHotkey = .rightControl
        model.autoCopyToClipboard = true
        model.autoPasteTranscription = false
        model.selectedLanguage = "de"
        model.bedrockMonthlyBudgetUSD = 0.75
        XCTAssertEqual(AppPreferences.shared.bedrockMonthlyBudgetUSD, 0.75, accuracy: 0.0001)
        // Before the fix, any stepper change recursed in didSet until the stack overflowed.
        model.bedrockMonthlyBudgetUSD = 0.01
        XCTAssertEqual(model.bedrockMonthlyBudgetUSD, 0.05, accuracy: 0.0001)
        let prefs = AppPreferences.shared
        XCTAssertTrue(prefs.holdToRecord)
        XCTAssertEqual(prefs.secondaryModifierOnlyHotkey, ModifierKey.rightControl.rawValue)
        XCTAssertEqual(prefs.modifierOnlyHotkey, ModifierKey.rightOption.rawValue, "The primary key is unchanged")
        XCTAssertTrue(prefs.autoCopyToClipboard)
        XCTAssertFalse(prefs.autoPasteTranscription)
        XCTAssertEqual(prefs.whisperLanguage, "de")
        XCTAssertEqual(prefs.bedrockMonthlyBudgetUSD, 0.05, accuracy: 0.0001, "The stop keeps its existing $0.05 floor")
    }

    func testCostStopDefaultsToTwentyFiveCentsAndOn() {
        let standard = UserDefaults.standard
        standard.removeObject(forKey: "bedrockMonthlyBudgetUSD")
        standard.removeObject(forKey: "bedrockMonthlyBudgetEnabled")
        let model = SettingsViewModel(credentials: stub())
        XCTAssertTrue(model.bedrockMonthlyBudgetEnabled)
        XCTAssertEqual(model.bedrockMonthlyBudgetUSD, 0.25, accuracy: 0.0001)
        XCTAssertNil(standard.object(forKey: "bedrockMonthlyBudgetUSD"), "Reading the default stores nothing")
    }

    // MARK: Control+Fn

    func testControlFnIsOptInAndRoundTripsThePreviousShortcut() {
        let prefs = AppPreferences.shared
        let model = SettingsViewModel(credentials: stub())
        XCTAssertEqual(model.modifierChordHotkey, .none)
        XCTAssertEqual(RecordingTriggerConfiguration(), .modifierKeys(primary: .rightOption, secondary: .leftControl), "Today's trigger until chosen")

        model.modifierChordHotkey = .controlFn
        XCTAssertEqual(prefs.modifierChordHotkey, "controlFn")
        XCTAssertEqual(RecordingTriggerConfiguration(), .chord(.controlFn))
        XCTAssertEqual(prefs.modifierOnlyHotkey, ModifierKey.rightOption.rawValue, "The modifier keys stay stored")
        XCTAssertEqual(prefs.secondaryModifierOnlyHotkey, ModifierKey.leftControl.rawValue)

        model.modifierChordHotkey = .none
        XCTAssertEqual(RecordingTriggerConfiguration(), .modifierKeys(primary: .rightOption, secondary: .leftControl), "Switching back restores both keys")
        XCTAssertEqual(SettingsViewModel(credentials: stub()).modifierChordHotkey, .none)
    }

    func testDictationPaneWithControlFnRendersWithoutWriting() throws {
        UserDefaults.standard.set(ModifierChord.controlFn.rawValue, forKey: "modifierChordHotkey")
        for size in [CGSize(width: 600, height: 560), CGSize(width: 760, height: 680)] {
            for scheme in [ColorScheme.light, .dark] {
                let bitmap = try render(
                    SettingsView(selection: .constant(.dictation), credentials: stub(), size: size),
                    size: size,
                    scheme: scheme,
                    name: "settings-dictation-controlfn-\(Int(size.width))"
                )
                XCTAssertEqual(purplePixels(in: bitmap), 0)
            }
        }
        XCTAssertEqual(UserDefaults.standard.string(forKey: "modifierChordHotkey"), ModifierChord.controlFn.rawValue)
        XCTAssertTrue(DictationSettingsView.chordHelp.contains("Press 🌐 key to Do Nothing"))
        XCTAssertTrue(DictationSettingsView.chordHelp.contains("alone does nothing"))
    }

    // MARK: Speech model

    func testSpeechModelPickerAlwaysShowsTheCurrentModel() {
        let model = SettingsViewModel(credentials: stub())
        XCTAssertEqual(model.currentSpeechModel, .parakeet(version: "v3"))
        model.downloadableFluidAudioModels = SettingsFluidAudioModels.availableModels
        model.availableModels = []
        let missing = model.speechModelOptions
        XCTAssertEqual(missing.map(\.choice), [.parakeet(version: "v3")])
        XCTAssertEqual(missing.first?.name, "Parakeet v3 (not downloaded)")

        model.downloadableFluidAudioModels = SettingsFluidAudioModels.availableModels.map { var m = $0; m.isDownloaded = true; return m }
        model.availableModels = [
            URL(fileURLWithPath: "/tmp/models/ggml-large-v3-turbo.bin"),
            URL(fileURLWithPath: "/tmp/models/ggml-custom.bin"),
        ]
        let options = model.speechModelOptions
        XCTAssertEqual(options.map(\.choice), [
            .parakeet(version: "v3"), .parakeet(version: "v2"),
            .whisper(filename: "ggml-large-v3-turbo.bin"), .whisper(filename: "ggml-custom.bin"),
        ])
        XCTAssertEqual(options.map(\.name), ["Parakeet v3", "Parakeet v2", "Whisper Turbo V3 large", "ggml-custom"])
        XCTAssertEqual(model.speechModelDetail(.parakeet(version: "v3")), "Multilingual, 25 languages · Runs on this Mac")
    }

    // MARK: Routing

    func testPanesAreTheFourDestinationsInOrder() {
        XCTAssertEqual(SettingsPane.allCases, [.dictation, .cleanup, .personalize, .providerCost])
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["Dictation", "Cleanup", "Personalize", "Provider & Cost"])
    }

    // MARK: History wording

    func testHistoryNamesTheOriginalTranscriptInsteadOfAFallback() {
        func card(_ source: TranscriptCleanupOutcome.Source, hasAudio: Bool = true) -> RecordingCard {
            RecordingCard(
                recording: Recording(id: UUID(), timestamp: Date(), fileName: "fixture.wav", transcription: "Fixture words.",
                                     duration: 3, status: .completed, progress: 1, cleanupSource: source),
                searchQuery: "", isPlaying: false, hasAudio: hasAudio,
                onPlay: {}, onCopy: {}, onDelete: {}, onRegenerate: {}
            )
        }
        XCTAssertEqual(card(.rawFallback).cleanupBadgeLabel, "Original transcript")
        XCTAssertTrue(card(.rawFallback).cleanupBadgeHelp.contains("didn’t finish"))
        XCTAssertTrue(card(.rawFallback).cleanupBadgeHelp.contains("Regenerate"))
        XCTAssertFalse(card(.rawFallback, hasAudio: false).cleanupBadgeHelp.contains("Regenerate"), "No Regenerate without audio")
        XCTAssertEqual(card(.budgetLimited).cleanupBadgeLabel, "Cost stop reached")
        XCTAssertEqual(card(.disabled).cleanupBadgeLabel, "Cleanup off")
        XCTAssertEqual(card(.bedrock).cleanupBadgeLabel, "Bedrock")
        for source in [TranscriptCleanupOutcome.Source.rawFallback, .budgetLimited, .disabled] {
            XCTAssertFalse(card(source).cleanupBadgeHelp.localizedCaseInsensitiveContains("fallback"))
            XCTAssertFalse(card(source).cleanupBadgeHelp.contains("cleaned by"), "Never claims AI cleaned the original")
        }
    }

    func testAppTextNeverSaysFallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper")
        let literal = try NSRegularExpression(pattern: #""[^"\n]*fallback[^"\n]*""#, options: [.caseInsensitive])
        var hits: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let interpolation = try NSRegularExpression(pattern: #"\\\([^()]*\)"#)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let text = interpolation.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "")
            for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                hits.append("\(file.lastPathComponent): \(Range(match.range, in: text).map { String(text[$0]) } ?? "")")
            }
        }
        XCTAssertEqual(hits, [], "Say what happened, e.g. “original transcript”")
    }

    // MARK: Rendering

    private func hostedView<V: View>(_ view: V, size: CGSize) throws -> NSView {
        let host = NSHostingView(rootView: view.defaultAppStorage(appStorage))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(window.isVisible, "Keyboard checks stay offscreen")
        retainedWindows.append(window)
        return host
    }

    private var retainedWindows: [NSWindow] = []

    @discardableResult
    private func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, name: String?) throws -> NSBitmapImageRep {
        let content = view
            .environment(\.colorScheme, scheme)
            .defaultAppStorage(appStorage)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        if let name {
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let fileName = "\(name)-\(scheme == .dark ? "dark" : "light")"
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = fileName
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["WORKFLOW_RENDER_DIR"] {
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(fileName).png"))
            }
        }
        XCTAssertFalse(window.isVisible, "Visual verification must stay offscreen")
        return bitmap
    }

    /// Counts opaque violet-to-lavender pixels after converting to 8-bit sRGB.
    private func purplePixels(in bitmap: NSBitmapImageRep) -> Int {
        guard let srgb = bitmap.converting(to: .sRGB, renderingIntent: .default),
              srgb.bitsPerSample == 8, srgb.samplesPerPixel == 4, !srgb.isPlanar,
              let data = srgb.bitmapData else { return Int.max }
        var count = 0
        for y in 0..<srgb.pixelsHigh {
            for x in 0..<srgb.pixelsWide {
                let p = data + y * srgb.bytesPerRow + x * 4
                guard p[3] > 127 else { continue }
                let color = NSColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
                let hue = color.hueComponent * 360
                if (225...335).contains(hue), color.saturationComponent > 0.3, color.brightnessComponent > 0.25 { count += 1 }
            }
        }
        return count
    }
}
