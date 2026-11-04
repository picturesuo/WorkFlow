import Foundation
import GRDB
import XCTest
@testable import OpenSuperWhisper

// Integrated pressure tests across the share-ready features: an existing
// History and preferences upgrading through every later migration and
// relaunch, the native and compatible providers reached through the
// production factory from the production queue, Learn and regeneration, and
// burst or late replies through the production queue and indicator.
// Recognizer words and provider replies are synthetic and every key is a
// runtime-built placeholder, so these prove wiring, persistence, and guards,
// not real speech, paste, or model quality. Nothing reaches a microphone,
// Keychain, the network, the general pasteboard, the user's preferences, or
// their History, and nothing is shown on screen.

/// Placeholder keys, assembled at runtime so no key-shaped literal is in source.
private enum PressureKeys {
    static let openAI = ["sk", "proj", "PRESSUREfixture" + String(repeating: "7", count: 25)].joined(separator: "-")
    static let anthropic = ["sk", "ant", "api03", "PRESSUREfixture" + String(repeating: "7", count: 23)].joined(separator: "-")
    static let compatible = ["compatible", "pressure", "fixture"].joined(separator: "-")
    static let bedrock = ["bedrock", "pressure", "fixture"].joined(separator: "-")
    static let all = [openAI, anthropic, compatible, bedrock]

    static func key(for provider: CleanupProviderID) -> String {
        switch provider {
        case .openAI: openAI
        case .anthropic: anthropic
        case .bedrock: bedrock
        default: compatible
        }
    }
}

/// Answers provider requests in process and records exactly what was sent.
/// A reply can be held until the test releases it, so a test decides when a
/// late reply arrives. URL loading calls in on its own threads, so shared
/// state is behind one lock.
final class PressureProviderProtocol: URLProtocol {
    enum Reply {
        case http(status: Int, body: String)
        case hang
        /// Delivered only after `release(key)`, unless the request is cancelled first.
        case held(key: String, status: Int, body: String)
    }

    struct Sent {
        let request: URLRequest
        let body: Data
        /// Every string in the JSON body, so a check never depends on escaping.
        var strings: [String] { PressureProviderProtocol.strings(in: body) }
        var text: String { strings.joined(separator: "\n") }
        var rawBody: String { String(decoding: body, as: UTF8.self) }

        /// The transcript a cleanup request carries, or nil for a chat request.
        var transcript: String? {
            for value in strings {
                guard let start = value.range(of: "<transcript>\n"),
                      let end = value.range(of: "\n</transcript>", range: start.upperBound..<value.endIndex) else { continue }
                return String(value[start.upperBound..<end.lowerBound])
            }
            return nil
        }
    }

    private static let lock = NSLock()
    private static var handlerStorage: ((Sent) -> Reply)?
    private static var sentStorage: [Sent] = []
    private static var releasedStorage: Set<String> = []
    private let stateLock = NSLock()
    private var isStopped = false

    static var handler: ((Sent) -> Reply)? {
        get { lock.withLock { handlerStorage } }
        set { lock.withLock { handlerStorage = newValue } }
    }

    static var sent: [Sent] { lock.withLock { sentStorage } }

    static func reset() {
        lock.withLock {
            handlerStorage = nil
            sentStorage = []
            releasedStorage = []
        }
    }

    static func release(_ key: String) {
        lock.withLock { _ = releasedStorage.insert(key) }
    }

    private static func isReleased(_ key: String) -> Bool {
        lock.withLock { releasedStorage.contains(key) }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PressureProviderProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let sent = Sent(request: request, body: ProviderFixtureProtocol.body(of: request))
        let handler = Self.lock.withLock { () -> ((Sent) -> Reply)? in
            Self.sentStorage.append(sent)
            return Self.handlerStorage
        }
        switch handler?(sent) ?? .http(status: 500, body: "{}") {
        case .hang:
            return
        case .http(let status, let body):
            deliver(status: status, body: body)
        case .held(let key, let status, let body):
            DispatchQueue.global().async {
                while !Self.isReleased(key) {
                    if self.stateLock.withLock({ self.isStopped }) { return }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                guard !self.stateLock.withLock({ self.isStopped }) else { return }
                self.deliver(status: status, body: body)
            }
        }
    }

    override func stopLoading() {
        stateLock.withLock { isStopped = true }
    }

    private func deliver(status: Int, body: String) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func strings(in body: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return [] }
        var result: [String] = []
        func walk(_ value: Any) {
            if let string = value as? String {
                result.append(string)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            } else if let dictionary = value as? [String: Any] {
                for key in dictionary.keys.sorted() { walk(dictionary[key]!) }
            }
        }
        walk(object)
        return result
    }
}

/// Provider-shaped replies for every provider the factory builds.
private enum PressureReplies {
    /// What the scripted provider makes of a transcript: capitalized, with a period.
    static func cleaned(_ transcript: String) -> String {
        transcript.prefix(1).uppercased() + transcript.dropFirst() + "."
    }

    static func body(_ provider: CleanupProviderID, _ text: String, thinking: String? = nil) -> String {
        switch provider {
        case .anthropic:
            var blocks: [[String: Any]] = []
            if let thinking { blocks.append(["type": "thinking", "thinking": thinking, "signature": "fixture-signature"]) }
            blocks.append(["type": "text", "text": text])
            return ProviderFixtureReplies.anthropic(blocks)
        case .bedrock:
            return bedrock([["text": text]])
        default:
            return ProviderFixtureReplies.openAI(text)
        }
    }

    static func bedrock(_ content: [[String: Any]], stopReason: String = "end_turn") -> String {
        encode([
            "output": ["message": ["role": "assistant", "content": content]],
            "stopReason": stopReason,
            "usage": ["inputTokens": 30, "outputTokens": 6, "totalTokens": 36]
        ])
    }

    static func error(_ provider: CleanupProviderID, status: Int) -> String {
        let echoed = "request rejected for \(PressureKeys.key(for: provider))"
        switch provider {
        case .anthropic:
            return ProviderFixtureReplies.anthropicError(echoed, type: status == 429 ? "rate_limit_error" : "authentication_error")
        case .bedrock:
            return encode(["message": echoed])
        default:
            return ProviderFixtureReplies.openAIError(echoed, type: "invalid_request_error", code: status == 429 ? "rate_limit_exceeded" : "invalid_api_key")
        }
    }

    /// A refusal, a reply with reasoning but no answer text, and a reply cut
    /// short, in each provider's own shape.
    static func refusal(_ provider: CleanupProviderID) -> String {
        switch provider {
        case .anthropic: ProviderFixtureReplies.anthropic([], stopReason: "refusal")
        case .bedrock: bedrock([["text": "Blocked."]], stopReason: "content_filtered")
        default: ProviderFixtureReplies.openAI(nil, refusal: "I can't help with that.")
        }
    }

    static func reasoningWithoutAnswer(_ provider: CleanupProviderID, reasoning: String) -> String {
        switch provider {
        case .anthropic:
            ProviderFixtureReplies.anthropic([["type": "thinking", "thinking": reasoning, "signature": "fixture-signature"]])
        case .bedrock:
            bedrock([["reasoningContent": ["reasoningText": ["text": reasoning, "signature": "fixture-signature"]]]])
        default:
            ProviderFixtureReplies.openAI(nil)
        }
    }

    static func truncated(_ provider: CleanupProviderID, _ text: String) -> String {
        switch provider {
        case .anthropic: ProviderFixtureReplies.anthropicText(text, stopReason: "max_tokens")
        case .bedrock: bedrock([["text": text]], stopReason: "max_tokens")
        default: ProviderFixtureReplies.openAI(text, finishReason: "length")
        }
    }

    private static func encode(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// Hears fixed words per audio file. A file can be held until released, and
/// a History file can share the words of the audio it was moved from.
private final class ScriptedSpeech: TranscriptionEngine {
    let isModelLoaded = true
    let engineName = "Scripted speech"
    private let lock = NSLock()
    private var wordsByFile: [String: String] = [:]
    private var heldFiles: Set<String> = []
    private var enteredFiles: [String] = []

    func say(_ words: String, in url: URL, held: Bool = false) {
        lock.withLock {
            wordsByFile[url.lastPathComponent] = words
            if held { heldFiles.insert(url.lastPathComponent) }
        }
    }

    func alias(_ url: URL, to original: URL) {
        lock.withLock { wordsByFile[url.lastPathComponent] = wordsByFile[original.lastPathComponent] }
    }

    func release(_ url: URL) {
        lock.withLock { _ = heldFiles.remove(url.lastPathComponent) }
    }

    var entered: [String] { lock.withLock { enteredFiles } }

    func initialize() async throws {}
    func getSupportedLanguages() -> [String] { ["en"] }
    func cancelTranscription() {}

    func transcribeAudio(url: URL, settings: OpenSuperWhisper.Settings) async throws -> String {
        lock.withLock { enteredFiles.append(url.lastPathComponent) }
        while lock.withLock({ heldFiles.contains(url.lastPathComponent) }) {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        return lock.withLock { wordsByFile[url.lastPathComponent] ?? "" }
    }
}

/// A local cleanup provider that capitalizes and adds a period.
private struct CapitalizingCleanup: TranscriptCleanupProviding {
    let providerID = CleanupProviderID.ollama

    func clean(transcript: String, systemPrompt: String, filter: CleanupFilterSnapshot) async throws -> CleanupProviderResult {
        CleanupProviderResult(text: PressureReplies.cleaned(transcript), inputTokens: 10, outputTokens: 10, modelID: "local")
    }
}

/// Shared setup: the test host's own preferences are saved and restored, and
/// every provider is the production factory's, with placeholder keys and the
/// in-process fixture session.
@MainActor
class ProviderPressureCase: XCTestCase {
    static let preferenceKeys = [
        "cleanupProviderID", "openAIModelID", "openAIReasoningEffort", "openAITimeoutSeconds",
        "anthropicModelID", "anthropicTimeoutSeconds", "openAICompatibleModelID", "openAICompatibleBaseURL",
        "openAICompatibleTimeoutSeconds", "bedrockRegion", "bedrockModelID", "bedrockTimeoutSeconds", "targetAppRulesData",
        CustomCleanupFilterStore.modeKey, CustomCleanupFilterStore.selectedIDKey, CustomCleanupFilterStore.dataKey,
        FilterAutoSettings.enabledKey, FilterAutoSettings.fallbackKey,
        LearnedPreferenceStore.dataKey, LearnedPreferenceStore.enabledKey, LearnedPreferenceStore.reviewedKey,
    ]
    private var savedPreferences: [String: Any] = [:]
    var session: URLSession!
    var scratch: [URL] = []
    var failures: [String?] = []

    override func setUp() async throws {
        try await super.setUp()
        for key in Self.preferenceKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedPreferences[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        PressureProviderProtocol.reset()
        session = PressureProviderProtocol.session()
        failures = []
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        PressureProviderProtocol.reset()
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        for key in Self.preferenceKeys {
            if let value = savedPreferences[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedPreferences = [:]
        try await super.tearDown()
    }

    var environment: CleanupProviderFactory.Environment {
        let session = session!
        return CleanupProviderFactory.Environment(
            loadBedrockKey: { PressureKeys.bedrock },
            loadCleanupKey: { account in
                switch account {
                case .openAI: PressureKeys.openAI
                case .anthropic: PressureKeys.anthropic
                case .openAICompatible: PressureKeys.compatible
                case .azureOpenAI: nil
                }
            },
            session: session,
            bedrockService: BedrockCleanupService(session: session)
        )
    }

    func select(_ provider: CleanupProviderID, timeout: Double = 5) {
        let prefs = AppPreferences.shared
        prefs.cleanupProviderID = provider.rawValue
        prefs.openAIModelID = "gpt-6-luna"
        prefs.openAIReasoningEffort = OpenAIReasoningEffort.none.rawValue
        prefs.openAITimeoutSeconds = timeout
        prefs.anthropicModelID = "claude-haiku-5-5"
        prefs.anthropicTimeoutSeconds = timeout
        prefs.openAICompatibleBaseURL = "https://compatible.example/v1"
        prefs.openAICompatibleModelID = "pressure-model"
        prefs.openAICompatibleTimeoutSeconds = timeout
        prefs.bedrockRegion = "us-east-1"
        prefs.bedrockModelID = BedrockCleanupConfiguration.defaultModelID
        prefs.bedrockTimeoutSeconds = timeout
    }

    func makeStore() throws -> RecordingStore {
        try RecordingStore(
            database: DatabaseQueue(), recordingsDirectory: Recording.recordingsDirectory,
            cancelQueuedRecording: { _ in }, stopPlayback: { _ in }
        )
    }

    /// The production pipeline with the selected provider from the factory.
    func makePipeline() -> TranscriptCleanupPipeline {
        let environment = environment
        return TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: { try CleanupProviderFactory.makeSelected(environment: environment) },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { nil },
            filterProvider: { CustomCleanupFilterStore.currentSnapshot() },
            autoConfigProvider: { FilterAutoSettings.currentConfig() },
            failureRecorder: { [weak self] in self?.failures.append($0) }
        )
    }

    func audio(seconds: Double = 1) throws -> URL {
        try FileManager.default.createDirectory(at: AudioRecorder.temporaryRecordingsDirectory, withIntermediateDirectories: true)
        let url = AudioRecorder.temporaryRecordingsDirectory.appendingPathComponent("pressure-\(UUID().uuidString).wav")
        try writeSilentWAV(to: url, seconds: seconds)
        scratch.append(url)
        return url
    }

    /// Waits until the queue is idle and no row is pending, then returns History newest first.
    func settled(_ queue: TranscriptionQueue, _ store: RecordingStore, rows: Int) async throws -> [Recording] {
        for _ in 0..<1_000 {
            let all = try await store.fetchRecordings(limit: 100, offset: 0)
            if !queue.isProcessing, all.count == rows, all.allSatisfy({ !$0.isPending }) {
                scratch.append(contentsOf: all.map(\.url))
                return all
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The queue did not settle")
        return try await store.fetchRecordings(limit: 100, offset: 0)
    }

    /// The single History row once the queue settles.
    func onlyRow(_ queue: TranscriptionQueue, _ store: RecordingStore) async throws -> Recording {
        let rows = try await settled(queue, store, rows: 1)
        return try XCTUnwrap(rows.first)
    }

    func waitUntil(_ condition: @escaping () -> Bool, _ message: String) async throws {
        var attempts = 0
        while !condition(), attempts < 1_000 {
            attempts += 1
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    /// The request goes only to the selected provider's documented endpoint,
    /// carries only that provider's key, in its header and nowhere else.
    func assertSafeTransport(_ sent: PressureProviderProtocol.Sent, _ provider: CleanupProviderID, file: StaticString = #filePath, line: UInt = #line) {
        let url = sent.request.url?.absoluteString ?? ""
        let key = PressureKeys.key(for: provider)
        let headers = sent.request.allHTTPHeaderFields ?? [:]
        switch provider {
        case .openAI:
            XCTAssertEqual(url, "https://api.openai.com/v1/chat/completions", file: file, line: line)
            XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)", file: file, line: line)
            XCTAssertNil(sent.request.value(forHTTPHeaderField: "x-api-key"), file: file, line: line)
        case .anthropic:
            XCTAssertEqual(url, "https://api.anthropic.com/v1/messages", file: file, line: line)
            XCTAssertEqual(sent.request.value(forHTTPHeaderField: "x-api-key"), key, file: file, line: line)
            XCTAssertNotNil(sent.request.value(forHTTPHeaderField: "anthropic-version"), file: file, line: line)
            XCTAssertNil(sent.request.value(forHTTPHeaderField: "Authorization"), file: file, line: line)
        case .bedrock:
            XCTAssertEqual(sent.request.url?.host, "bedrock-runtime.us-east-1.amazonaws.com", file: file, line: line)
            XCTAssertTrue(url.hasSuffix("/converse"), url, file: file, line: line)
            XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)", file: file, line: line)
        default:
            XCTAssertEqual(url, "https://compatible.example/v1/chat/completions", file: file, line: line)
            XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)", file: file, line: line)
        }
        XCTAssertEqual(sent.request.httpMethod, "POST", file: file, line: line)
        for candidate in PressureKeys.all {
            XCTAssertFalse(url.contains(candidate), "No key in the URL", file: file, line: line)
            XCTAssertFalse(sent.rawBody.contains(candidate), "No key in the body", file: file, line: line)
            if candidate != key {
                XCTAssertFalse(headers.values.contains { $0.contains(candidate) }, "Another provider's key is never sent", file: file, line: line)
            }
        }
    }

    func source(_ provider: CleanupProviderID) -> TranscriptCleanupOutcome.Source {
        switch provider {
        case .openAI: .openAI
        case .anthropic: .anthropic
        case .bedrock: .bedrock
        case .ollama: .ollama
        case .azureOpenAI: .azureOpenAI
        case .openAICompatible: .openAICompatible
        }
    }
}

// MARK: - Upgrade chain and relaunches

/// A History and preferences from before speaking timing, Auto filter choice,
/// and finished-writing learning upgrade in place, then survive relaunches.
@MainActor
final class UpgradeChainPressureTests: XCTestCase {
    private func openStore(_ path: String) throws -> RecordingStore {
        try RecordingStore(
            database: DatabaseQueue(path: path),
            recordingsDirectory: FileManager.default.temporaryDirectory,
            cancelQueuedRecording: { _ in },
            stopPlayback: { _ in }
        )
    }

    func testAnOlderHistoryAndPreferencesUpgradeThroughEveryMigrationAndSurviveThreeLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pressure-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("recordings.sqlite").path
        let suite = "UpgradeChainPressureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Preferences as an earlier version stored them: a saved filter
        // without digits or trigger phrases, the filter selected by hand, no
        // Auto keys, and learned preferences from before saved filters
        // learned (no filter id, no sources) next to one a filter learned.
        let standupID = UUID()
        let liveID = UUID(), windowID = UUID(), legacyID = UUID(), meetingID = UUID(), queuedID = UUID()
        let builtInPreferenceID = UUID(), filterPreferenceID = UUID()
        defaults.set(Data(#"[{"id":"\#(standupID.uuidString)","name":"Standup notes","baseMode":"writing","instructions":"Write short standup sentences."}]"#.utf8),
                     forKey: CustomCleanupFilterStore.dataKey)
        defaults.set(standupID.uuidString, forKey: CustomCleanupFilterStore.selectedIDKey)
        defaults.set("writing", forKey: CustomCleanupFilterStore.modeKey)
        defaults.set(Data("""
        [{"id":"\(builtInPreferenceID.uuidString)","mode":"technical","kind":"semicolon_join","isEnabled":true,"origin":"cleanup","evidence":["a1"],"fromLegacyOnly":false,"learnedAt":700000000,"updatedAt":700000000},
         {"id":"\(filterPreferenceID.uuidString)","mode":"writing","kind":"contractions","isEnabled":true,"origin":"final_edit","evidence":["b1"],"fromLegacyOnly":false,"learnedAt":700000001,"updatedAt":700000001,"filterID":"\(standupID.uuidString)","sourceRecordingIDs":["\(liveID.uuidString)"]}]
        """.utf8), forKey: LearnedPreferenceStore.dataKey)

        let standup = try XCTUnwrap(CustomCleanupFilterStore.load(from: defaults).first)
        let filterPreference = try XCTUnwrap(LearnedPreferenceStore.load(from: defaults).first { $0.id == filterPreferenceID })
        let queuedAudio = directory.appendingPathComponent("queued.wav")
        try writeSilentWAV(to: queuedAudio, seconds: 1)

        // History written by the current schema, then taken back to v10.
        do {
            let store = try openStore(path)
            let standupSnapshot = CleanupFilterSnapshot(filter: standup, learned: [filterPreference])
            func row(_ id: UUID, _ text: String, at seconds: Double, mode: RecordingMode = .dictation, status: RecordingStatus = .completed,
                     filter: CleanupFilterSnapshot? = nil, sourceFile: String? = nil) -> Recording {
                Recording(id: id, timestamp: Date(timeIntervalSince1970: seconds), fileName: "\(id).wav", transcription: text, duration: 12,
                          status: status, progress: status == .completed ? 1 : 0, sourceFileURL: sourceFile,
                          cleanupSource: filter == nil ? nil : .ollama, mode: mode, cleanupRequested: filter != nil,
                          cleanupMode: filter?.mode, cleanupFilterName: filter?.customName, cleanupFilterInstructions: filter?.customInstructions)
            }
            try await store.addRecordingSync(
                row(liveID, "We shipped the beta to testers.", at: 2_000_000_001, filter: standupSnapshot),
                source: DictationSource(recordingID: liveID, recordingStartedAt: Date(timeIntervalSince1970: 2_000_000_000),
                                        recognizerText: "we shipped the beta to testers", emittedText: "We shipped the beta to testers.",
                                        insertedText: "We shipped the beta to testers.", disposition: .pasteSent, filter: standupSnapshot,
                                        cleanupSource: .ollama)
            )
            try await store.addRecordingSync(
                row(windowID, "Notes from the main window.", at: 2_000_000_002, filter: .builtIn(.everyday)),
                source: DictationSource(recordingID: windowID, recognizerText: "notes from the main window",
                                        emittedText: "Notes from the main window.", disposition: .notInserted, filter: .builtIn(.everyday))
            )
            try await store.addRecordingSync(row(legacyID, "An old homework dictation.", at: 1_900_000_000, filter: .builtIn(.homework)))
            try await store.addRecordingSync(row(meetingID, "Meeting transcript.", at: 2_000_000_003, mode: .meeting))
            try await store.addRecordingSync(
                row(queuedID, "", at: 2_000_000_004, status: .pending, filter: .builtIn(.technical), sourceFile: queuedAudio.path),
                source: DictationSource(recordingID: queuedID, disposition: .pending, filter: .builtIn(.technical))
            )
        }
        do {
            let database = try DatabaseQueue(path: path)
            try await database.write { db in
                try db.execute(sql: "ALTER TABLE recordings DROP COLUMN cleanupFilterReason")
                try db.execute(sql: "ALTER TABLE recordings DROP COLUMN cleanupFilterAuto")
                try db.execute(sql: "ALTER TABLE dictation_sources DROP COLUMN filterReason")
                try db.execute(sql: "ALTER TABLE dictation_sources DROP COLUMN captureOrigin")
                try db.execute(sql: "ALTER TABLE dictation_sources DROP COLUMN processingSeconds")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v11_add_dictation_timing', 'v12_add_filter_choice')")
            }
            let applied = try await database.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
            XCTAssertEqual(applied.last, "v10_add_filter_writes_digits", "The database is at v10")
        }

        let ids: Set<UUID> = [liveID, windowID, legacyID, meetingID, queuedID]
        var firstLaunchRows: [Recording] = []
        var settledSummary: SpeakingSummary?
        for launch in 1...3 {
            let store = try openStore(path)
            let migrations = try await DatabaseQueue(path: path).read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
            XCTAssertEqual(migrations.filter { $0.hasPrefix("v11") || $0.hasPrefix("v12") }.count, 2, "launch \(launch)")
            XCTAssertEqual(Set(migrations).count, migrations.count, "No migration runs twice, launch \(launch)")

            let rows = try await store.fetchRecordings(limit: 20, offset: 0)
            XCTAssertEqual(Set(rows.map(\.id)), ids, "Every row and UUID survives, launch \(launch)")
            XCTAssertTrue(rows.filter { $0.id != queuedID }.allSatisfy { $0.cleanupFilterAuto == nil && $0.cleanupFilterReason == nil },
                          "No choice is invented for old rows")
            XCTAssertNil(rows.first { $0.id == queuedID }?.cleanupFilterAuto)
            XCTAssertEqual(rows.first { $0.id == queuedID }?.cleanupFilterReason, launch == 1 ? nil : .manual,
                           "The resumed row records the filter it was queued with as picked by hand")
            let live = try await store.dictationSource(for: liveID)
            XCTAssertEqual(live?.captureOrigin, .live, "Only a row with a recorded start is classified live")
            XCTAssertNil(live?.processingSeconds, "Processing time is never guessed")
            XCTAssertEqual(live?.filterID, standupID)
            XCTAssertEqual(live?.learnedPreferences.map(\.id), [filterPreferenceID])
            XCTAssertNil(live?.filterReason)
            let window = try await store.dictationSource(for: windowID)
            XCTAssertNil(window?.captureOrigin)

            if launch == 1 {
                firstLaunchRows = rows
                // The dictation still queued when the old version quit resumes
                // with the filter it captured, even though the selection is
                // now a saved filter.
                let engine = ScriptedSpeech()
                engine.say("check the replica lag first then deploy", in: queuedAudio)
                let pipeline = TranscriptCleanupPipeline(
                    isEnabled: { true }, providerResolver: { CapitalizingCleanup() }, vocabularyProvider: { [] },
                    appRuleProvider: { _ in nil }, bedrockBudgetProvider: { nil }, failureRecorder: { _ in }
                )
                let queue = TranscriptionQueue(
                    transcriptionService: TranscriptionService(engine: engine), recordingStore: store,
                    cleanupPipeline: pipeline, learningDefaults: defaults
                )
                queue.startProcessingQueue()
                for _ in 0..<500 {
                    if let row = try await store.fetchRecordings(limit: 20, offset: 0).first(where: { $0.id == queuedID }),
                       !row.isPending, !queue.isProcessing { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let resumed = try await store.fetchRecordings(limit: 20, offset: 0).first { $0.id == queuedID }
                XCTAssertEqual(resumed?.transcription, "Check the replica lag first then deploy.")
                XCTAssertEqual(resumed?.cleanupMode, .technical, "It keeps the filter captured before the upgrade")
                XCTAssertNil(resumed?.cleanupFilterName)
                if let resumed { try? FileManager.default.removeItem(at: resumed.url) }
            } else {
                for row in rows where row.id != queuedID {
                    let before = try XCTUnwrap(firstLaunchRows.first { $0.id == row.id })
                    XCTAssertEqual(row.transcription, before.transcription, "launch \(launch)")
                    XCTAssertEqual(row.cleanupFilterName, before.cleanupFilterName, "launch \(launch)")
                    XCTAssertEqual(row.cleanupMode, before.cleanupMode, "launch \(launch)")
                }
                XCTAssertEqual(rows.first { $0.id == queuedID }?.transcription, "Check the replica lag first then deploy.")
            }

            // Speaking versus typing: the live row is compared on recording
            // time only, the rest are named exclusions, never measured savings.
            let summary = try await store.speakingSummary(since: .distantPast)
            XCTAssertTrue(summary.measured.isEmpty, "launch \(launch)")
            XCTAssertEqual(summary.recordingOnly.count, 1, "launch \(launch)")
            XCTAssertEqual(summary.recordingOnly.producedWords, 6)
            if launch == 1 {
                // Counted after the queued row finished: it has no origin, so it is legacy.
                XCTAssertEqual(summary.exclusions, [.legacy: 3, .meeting: 1])
                settledSummary = summary
            } else {
                XCTAssertEqual(summary, settledSummary, "The summary is identical on every launch")
            }

            // Preferences: the filter reads with no phrases and digits off,
            // Auto stays off, the hand-picked filter stays selected with its
            // own learned preference, and the built-in preference applies to
            // its mode only.
            let filters = CustomCleanupFilterStore.load(from: defaults)
            XCTAssertEqual(filters.map(\.id), [standupID])
            XCTAssertEqual(filters.first?.triggers, [])
            XCTAssertEqual(filters.first?.writesDigits, false)
            XCTAssertFalse(FilterAutoSettings.isEnabled(in: defaults))
            XCTAssertEqual(CustomCleanupFilterStore.currentSelection(in: defaults), .custom(standupID))
            let plan = FilterAutoSettings.currentPlan(in: defaults)
            XCTAssertNil(plan.autoConfig)
            XCTAssertEqual(plan.provisionalFilter.customID, standupID)
            XCTAssertEqual(plan.provisionalFilter.learned.map(\.id), [filterPreferenceID])
            XCTAssertEqual(LearnedPreferenceStore.activePreferences(for: .technical, in: defaults).map(\.id), [builtInPreferenceID])
            XCTAssertNil(LearnedPreferenceStore.load(from: defaults).first { $0.id == builtInPreferenceID }?.filterID)
            XCTAssertTrue(LearnedPreferenceStore.activePreferences(for: .writing, in: defaults).isEmpty, "Writing never inherits the filter's list")
            XCTAssertEqual(LearnedPreferenceStore.preferences(for: .filter(standup), in: defaults).first?.sourceRecordingIDs, [liveID])

            // Finished-writing learning still finds the upgraded dictations by
            // what they were made with.
            let candidates = try await store.learningCandidates()
            XCTAssertEqual(Set(candidates.map(\.id)), [liveID, windowID, legacyID, queuedID], "Meetings never teach")
        }
    }
}

// MARK: - Native and compatible providers through the production factory

@MainActor
final class NativeProviderJourneyTests: ProviderPressureCase {
    private let providers: [CleanupProviderID] = [.openAI, .anthropic, .bedrock, .openAICompatible]

    /// A queued dictation and a hand-picked regeneration, from the queue
    /// through the factory to each provider's own endpoint and back to History.
    func testEveryProviderCarriesAQueuedDictationAndARegenerationToHistory() async throws {
        let standup = CustomCleanupFilter(name: "Standup notes", baseMode: .writing, instructions: "Write short standup sentences.")
        try CustomCleanupFilterStore.upsert(standup)
        let spoken = "send the weekly report to the design team by friday"
        for provider in providers {
            PressureProviderProtocol.reset()
            failures = []
            select(provider)
            PressureProviderProtocol.handler = { sent in
                guard let transcript = sent.transcript else { return .http(status: 400, body: "{}") }
                return .http(status: 200, body: PressureReplies.body(provider, PressureReplies.cleaned(transcript), thinking: "PRIVATE-REASONING"))
            }
            let store = try makeStore()
            let engine = ScriptedSpeech()
            let queue = TranscriptionQueue(transcriptionService: TranscriptionService(engine: engine), recordingStore: store, cleanupPipeline: makePipeline())
            let url = try audio()
            engine.say(spoken, in: url)

            await queue.addFileToQueue(url: url, cleanupRequested: true, captureOrigin: .live)
            let first = try await onlyRow(queue, store)
            XCTAssertEqual(first.transcription, "Send the weekly report to the design team by friday.", "\(provider)")
            XCTAssertEqual(first.cleanupSource, source(provider), "\(provider)")
            XCTAssertEqual(first.cleanupMode, .everyday)
            XCTAssertEqual(PressureProviderProtocol.sent.count, 1, "\(provider)")
            assertSafeTransport(PressureProviderProtocol.sent[0], provider)
            let evidence = try await store.dictationSource(for: first.id)
            XCTAssertEqual(evidence?.emittedText, first.transcription)
            XCTAssertEqual(evidence?.recognizerText, spoken)
            let figures = try await store.speakingSummary(since: .distantPast)

            // Regenerate with a saved filter picked in History.
            engine.alias(first.url, to: url)
            await queue.requeueRecording(first, with: .custom(standup.id))
            let regenerated = try await onlyRow(queue, store)
            XCTAssertEqual(regenerated.id, first.id)
            XCTAssertEqual(regenerated.transcription, "Send the weekly report to the design team by friday.", "\(provider)")
            XCTAssertEqual(regenerated.cleanupFilterName, "Standup notes")
            XCTAssertEqual(regenerated.cleanupFilterReason, .manual)
            XCTAssertEqual(PressureProviderProtocol.sent.count, 2, "\(provider)")
            let second = PressureProviderProtocol.sent[1]
            assertSafeTransport(second, provider)
            XCTAssertTrue(second.text.contains("Write short standup sentences."), "The picked filter reaches \(provider)")
            XCTAssertFalse(PressureProviderProtocol.sent[0].text.contains("Write short standup sentences."))
            XCTAssertFalse(regenerated.transcription.contains("PRIVATE-REASONING"), "Reasoning never reaches History")
            let unchanged = try await store.dictationSource(for: first.id)
            XCTAssertEqual(unchanged?.emittedText, evidence?.emittedText, "The original evidence is kept")
            XCTAssertNil(unchanged?.filterName, "Evidence names the filter the dictation was made with")
            let refigured = try await store.speakingSummary(since: .distantPast)
            XCTAssertEqual(refigured, figures, "A regeneration never changes speaking figures")
            XCTAssertEqual(failures, [nil, nil], "\(provider)")
        }
    }

    /// Every failure a provider can return during a regeneration keeps the
    /// spoken words in History and the original evidence, and records only
    /// the fixed safe message.
    func testRegenerationFailuresKeepTheSpokenWordsAndTheOriginalEvidence() async throws {
        let spoken = "remind the team that the launch moved to tuesday"
        for provider in [CleanupProviderID.openAI, .anthropic, .bedrock] {
            PressureProviderProtocol.reset()
            failures = []
            select(provider, timeout: 0.5)
            PressureProviderProtocol.handler = { sent in
                .http(status: 200, body: PressureReplies.body(provider, PressureReplies.cleaned(sent.transcript ?? "")))
            }
            let store = try makeStore()
            let engine = ScriptedSpeech()
            let queue = TranscriptionQueue(transcriptionService: TranscriptionService(engine: engine), recordingStore: store, cleanupPipeline: makePipeline())
            let url = try audio()
            engine.say(spoken, in: url)
            await queue.addFileToQueue(url: url, cleanupRequested: true, captureOrigin: .live)
            var row = try await onlyRow(queue, store)
            engine.alias(row.url, to: url)
            let evidence = try await store.dictationSource(for: row.id)
            XCTAssertEqual(evidence?.emittedText, "Remind the team that the launch moved to tuesday.")

            let faults: [(String, PressureProviderProtocol.Reply)] = [
                ("rejected key", .http(status: 401, body: PressureReplies.error(provider, status: 401))),
                ("rate limit", .http(status: 429, body: PressureReplies.error(provider, status: 429))),
                ("server error", .http(status: 503, body: #"{"unexpected":true}"#)),
                ("timeout", .hang),
                ("malformed body", .http(status: 200, body: #"{"choices": ["#)),
                ("refusal", .http(status: 200, body: PressureReplies.refusal(provider))),
                ("reasoning without an answer", .http(status: 200, body: PressureReplies.reasoningWithoutAnswer(provider, reasoning: "PRIVATE-REASONING"))),
                ("cut short", .http(status: 200, body: PressureReplies.truncated(provider, "Remind the team"))),
                ("answered instead of rewriting", .http(status: 200, body: PressureReplies.body(provider, "Here is a short poem about launches instead.")))
            ]
            for (name, reply) in faults {
                PressureProviderProtocol.handler = { _ in reply }
                let before = PressureProviderProtocol.sent.count
                await queue.requeueRecording(row)
                row = try await onlyRow(queue, store)
                XCTAssertEqual(PressureProviderProtocol.sent.count, before + 1, "\(provider) \(name) reached the provider once")
                XCTAssertEqual(row.status, .completed, "\(provider) \(name)")
                XCTAssertEqual(row.transcription, spoken, "\(provider) \(name): the spoken words stay in History")
                XCTAssertEqual(row.cleanupSource, .rawFallback, "\(provider) \(name)")
                for secret in PressureKeys.all + ["PRIVATE-REASONING"] {
                    XCTAssertFalse(row.transcription.contains(secret), "\(provider) \(name)")
                }
                let kept = try await store.dictationSource(for: row.id)
                XCTAssertEqual(kept?.emittedText, evidence?.emittedText, "\(provider) \(name)")
                XCTAssertEqual(kept?.recognizerText, spoken, "\(provider) \(name)")
            }
            let expected: [String?] = [nil] + Array(repeating: TranscriptCleanupPipeline.safeFailureMessage, count: faults.count)
            XCTAssertEqual(failures, expected, "\(provider): only the fixed message is recorded")
        }
    }

    /// Learn sends only the matched edit with a little context through the
    /// selected provider, never the rest of the document, and saves only what
    /// the reply's answer text proposes.
    func testLearnSendsOnlyTheMatchedEditThroughEachProvider() async throws {
        let emitted = "Run the migration script against staging first. Then check the replica lag before touching production."
        let spoken = "run the migration script against staging first then check the replica lag before touching production"
        let privateParagraphs = [
            "PRIVATE-ALPHA My landlord renewed the lease for another year at the same rent.",
            "PRIVATE-BETA The pediatrician moved our appointment to the third week of March."
        ]
        let reply = #"{"preferences": [{"kind": "semicolon_join", "edits": [1]}]}"#
        for provider in [CleanupProviderID.openAI, .anthropic, .bedrock, .openAICompatible] {
            PressureProviderProtocol.reset()
            select(provider)
            PressureProviderProtocol.handler = { _ in
                .http(status: 200, body: PressureReplies.body(provider, reply, thinking: "PRIVATE-REASONING"))
            }
            let suite = "NativeProviderJourneyTests-learn-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = try makeStore()
            let id = UUID()
            let filter = CleanupFilterSnapshot.builtIn(.technical)
            let outcome = TranscriptCleanupOutcome(
                text: emitted, source: source(provider), inputTokens: 1, outputTokens: 1, modelID: "m", filter: filter,
                rawTokenEstimate: 1, finalTokenEstimate: 1, tokenEstimatorID: LocalTokenEstimator.identifier, cleanupInput: spoken
            )
            try await store.addRecordingSync(
                Recording(id: id, timestamp: Date(), fileName: "\(id).wav", transcription: emitted, duration: 5, status: .completed,
                          progress: 1, cleanupSource: source(provider), cleanupRequested: true, cleanupMode: .technical),
                source: DictationSource(recordingID: id, recognizerText: spoken, cleanup: outcome, fallbackFilter: filter,
                                        disposition: .pasteSent, insertedText: emitted, captureOrigin: .live)
            )
            let environment = environment
            let learning = CorrectionLearningSession(
                mode: .everyday,
                destination: CleanupProviderFactory.selectedDestination(),
                chatResolver: { try CleanupProviderFactory.makeSelectedChat(environment: environment) },
                budgetProvider: { nil },
                candidateProvider: { try await store.learningCandidates() },
                retentionProvider: { nil },
                sourceChecker: { try await store.existingRecordingIDs($0) },
                vocabularyAdder: { _ in XCTFail("Nothing is added to Vocabulary"); return false },
                defaults: defaults
            )
            learning.document = ([privateParagraphs[0], emitted.replacingOccurrences(of: "first. Then", with: "first; then"), privateParagraphs[1]])
                .joined(separator: "\n\n")

            learning.check()
            try await waitUntil({ !learning.isBusy }, "Check matches finished")
            XCTAssertTrue(PressureProviderProtocol.sent.isEmpty, "\(provider): Check matches sends nothing")
            XCTAssertTrue(LearnedPreferenceStore.load(from: defaults).isEmpty, "Check matches learns nothing")

            learning.learn()
            try await waitUntil({ !learning.isBusy }, "Learn finished")
            XCTAssertNil(learning.errorMessage, "\(provider)")
            XCTAssertEqual(PressureProviderProtocol.sent.count, 1, "\(provider)")
            let sent = PressureProviderProtocol.sent[0]
            assertSafeTransport(sent, provider)
            XCTAssertTrue(sent.text.contains("MODE: Technical"), "\(provider)")
            XCTAssertTrue(sent.text.contains("; then"), "\(provider): the matched edit is sent")
            for paragraph in privateParagraphs {
                XCTAssertFalse(sent.rawBody.contains(paragraph.prefix(13)), "\(provider): unmatched writing never leaves the Mac")
            }
            XCTAssertFalse(sent.text.contains(learning.document), "\(provider): the document itself is never sent")
            let learned = LearnedPreferenceStore.preferences(for: .technical, in: defaults)
            XCTAssertEqual(learned.map(\.kind), [.semicolonJoin], "\(provider)")
            XCTAssertEqual(learned.first?.sourceRecordingIDs, [id])
            XCTAssertFalse(learning.report?.summary.contains("PRIVATE-REASONING") ?? true)
        }
    }
}

// MARK: - Bursts, edits while queued, and late replies

@MainActor
final class BurstAndLateReplyPressureTests: ProviderPressureCase {
    private let semicolonInstruction = "Join closely related clauses with a semicolon rather than starting a new sentence."

    /// Five dictations queued in a burst while the engine is busy, with the
    /// selection, a saved filter, and a learned preference changed between
    /// and after them, and a regeneration in the middle. Every row gets its
    /// own words and the filter it captured; none is lost or crossed.
    func testABurstOfQueuedDictationsKeepsEachOnesWordsAndCapturedFilter() async throws {
        select(.openAICompatible)
        let store = try makeStore()
        let engine = ScriptedSpeech()
        let queue = TranscriptionQueue(transcriptionService: TranscriptionService(engine: engine), recordingStore: store, cleanupPipeline: makePipeline())
        PressureProviderProtocol.handler = { sent in
            guard let transcript = sent.transcript else { return .http(status: 400, body: "{}") }
            // Each reply waits until the test releases that transcript.
            return .held(key: transcript, status: 200, body: ProviderFixtureReplies.openAI(PressureReplies.cleaned(transcript)))
        }

        var standup = CustomCleanupFilter(name: "Standup notes", baseMode: .writing, instructions: "Write short standup sentences.")
        try CustomCleanupFilterStore.upsert(standup)
        let doomed = CustomCleanupFilter(name: "Lab report", baseMode: .homework, instructions: "Keep units next to numbers.")
        try CustomCleanupFilterStore.upsert(doomed)
        let semicolon = LearnedPreference(
            mode: .technical, kind: .semicolonJoin, from: nil, to: nil, origin: .finalEdit, evidence: ["synthetic"],
            fromLegacyOnly: false, learnedAt: Date(), updatedAt: Date()
        )
        LearnedPreferenceStore.save([semicolon])

        let words = [
            "first we ship the beta",
            "second we write the standup",
            "third the replica lag is fine",
            "fourth the sample weighs twelve grams",
            "fifth thanks everyone"
        ]
        let selections: [CleanupFilterSelection] = [
            .builtIn(.everyday), .custom(standup.id), .builtIn(.technical), .custom(doomed.id), .builtIn(.writing)
        ]
        var urls: [URL] = []
        for (index, spoken) in words.enumerated() {
            let url = try audio()
            engine.say(spoken, in: url, held: index == 0)
            urls.append(url)
            CustomCleanupFilterStore.select(selections[index])
            await queue.addFileToQueue(url: url, cleanupRequested: true, captureOrigin: .live)
        }
        try await waitUntil({ engine.entered.count == 1 }, "The first dictation holds the engine")

        // Edits after the burst was queued: none may reach queued work.
        standup.instructions = "EDITED AFTER QUEUEING."
        try CustomCleanupFilterStore.upsert(standup)
        _ = CustomCleanupFilterStore.delete(id: doomed.id)
        LearnedPreferenceStore.delete(semicolon.id)
        CustomCleanupFilterStore.select(.builtIn(.homework))

        engine.release(urls[0])
        for (index, spoken) in words.enumerated() {
            try await waitUntil({ PressureProviderProtocol.sent.count == index + 1 }, "Request \(index + 1) was sent")
            // Only one request is ever in flight: the queue is serial.
            XCTAssertEqual(PressureProviderProtocol.sent.last?.transcript, spoken)
            PressureProviderProtocol.release(spoken)
        }
        let rows = try await settled(queue, store, rows: 5)
        let byWords = Dictionary(uniqueKeysWithValues: try await recognizedRows(rows, store))
        for (index, spoken) in words.enumerated() {
            let row = try XCTUnwrap(byWords[spoken], spoken)
            XCTAssertEqual(row.transcription, PressureReplies.cleaned(spoken), "Each row has its own words")
            XCTAssertEqual(row.status, .completed)
            XCTAssertEqual(row.cleanupSource, .openAICompatible)
            let sent = try XCTUnwrap(PressureProviderProtocol.sent.first { $0.transcript == spoken })
            switch selections[index] {
            case .builtIn(let mode):
                XCTAssertEqual(row.cleanupMode, mode, spoken)
                XCTAssertNil(row.cleanupFilterName, spoken)
            case .custom:
                XCTAssertNotNil(row.cleanupFilterName, spoken)
            }
            XCTAssertFalse(sent.text.contains("EDITED AFTER QUEUEING."), "\(spoken): a later edit never reaches queued work")
        }
        let standupRequest = try XCTUnwrap(PressureProviderProtocol.sent.first { $0.transcript == words[1] })
        XCTAssertTrue(standupRequest.text.contains("Write short standup sentences."), "Queued work keeps the instructions it captured")
        let labRequest = try XCTUnwrap(PressureProviderProtocol.sent.first { $0.transcript == words[3] })
        XCTAssertTrue(labRequest.text.contains("Keep units next to numbers."), "A filter deleted after queueing still applies to work queued with it")
        XCTAssertEqual(byWords[words[3]]?.cleanupFilterName, "Lab report")
        let technicalRequest = try XCTUnwrap(PressureProviderProtocol.sent.first { $0.transcript == words[2] })
        XCTAssertTrue(technicalRequest.text.contains(semicolonInstruction), "Queued work keeps the learned preference it captured")

        // Regenerating the Technical row now: its deleted learned preference
        // stays deleted.
        let technical = try XCTUnwrap(byWords[words[2]])
        engine.alias(technical.url, to: urls[2])
        PressureProviderProtocol.handler = { sent in
            .http(status: 200, body: ProviderFixtureReplies.openAI(PressureReplies.cleaned(sent.transcript ?? "")))
        }
        await queue.requeueRecording(technical)
        let after = try await settled(queue, store, rows: 5)
        XCTAssertEqual(PressureProviderProtocol.sent.count, 6)
        XCTAssertFalse(try XCTUnwrap(PressureProviderProtocol.sent.last).text.contains(semicolonInstruction),
                       "A regeneration never brings back a deleted learned preference")
        XCTAssertEqual(after.first { $0.id == technical.id }?.transcription, PressureReplies.cleaned(words[2]))
        for row in after where row.id != technical.id {
            XCTAssertEqual(row.transcription, rows.first { $0.id == row.id }?.transcription, "Other rows are untouched")
        }
    }

    private func recognizedRows(_ rows: [Recording], _ store: RecordingStore) async throws -> [(String, Recording)] {
        var pairs: [(String, Recording)] = []
        for row in rows {
            let recognizer = try await store.dictationSource(for: row.id)?.recognizerText
            pairs.append((try XCTUnwrap(recognizer), row))
        }
        return pairs
    }

    /// An older dictation's cleanup reply arrives after a newer dictation was
    /// delivered. The newer text is the only one pasted; the older one is
    /// saved to History with its own words and is never pasted over it.
    func testALateCleanupReplyNeverPastesOverTheNewerDictation() async throws {
        for provider in [CleanupProviderID.openAI, .anthropic] {
            PressureProviderProtocol.reset()
            select(provider)
            let older = "please move the review to thursday"
            let newer = "actually keep the review on wednesday"
            PressureProviderProtocol.handler = { sent in
                guard let transcript = sent.transcript else { return .http(status: 400, body: "{}") }
                let body = PressureReplies.body(provider, PressureReplies.cleaned(transcript))
                return transcript == older ? .held(key: older, status: 200, body: body) : .http(status: 200, body: body)
            }
            let store = try makeStore()
            let engine = ScriptedSpeech()
            let service = TranscriptionService(engine: engine)
            let gate = LatestDictationGate()
            let pipeline = makePipeline()
            var delivered: [String] = []
            let olderModel = IndicatorViewModel(latestDictationGate: gate, transcriptionService: service, recordingStore: store,
                                                cleanupPipeline: pipeline, delivery: { delivered.append($0); return .pasteSent })
            let newerModel = IndicatorViewModel(latestDictationGate: gate, transcriptionService: service, recordingStore: store,
                                                cleanupPipeline: pipeline, delivery: { delivered.append($0); return .pasteSent })
            defer {
                olderModel.cleanup()
                newerModel.cleanup()
            }
            let olderAudio = try audio(), newerAudio = try audio()
            engine.say(older, in: olderAudio)
            engine.say(newer, in: newerAudio)

            let olderGeneration = gate.begin()
            let olderTask = Task { await olderModel.finishDictation(audioAt: olderAudio, generation: olderGeneration, recordingStartedAt: Date(), stoppedAt: .now) }
            try await waitUntil({ PressureProviderProtocol.sent.count == 1 }, "The older dictation reached the provider")

            let newerGeneration = gate.begin()
            await newerModel.finishDictation(audioAt: newerAudio, generation: newerGeneration, recordingStartedAt: Date(), stoppedAt: .now)
            XCTAssertEqual(delivered, [PressureReplies.cleaned(newer)], "\(provider)")

            PressureProviderProtocol.release(older)
            await olderTask.value
            XCTAssertEqual(delivered, [PressureReplies.cleaned(newer)], "\(provider): the late reply is never pasted")

            var rows: [Recording] = []
            for _ in 0..<300 {
                rows = try await store.fetchRecordings(limit: 10, offset: 0)
                if rows.count == 2 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            scratch.append(contentsOf: rows.map(\.url))
            XCTAssertEqual(Set(rows.map(\.transcription)), [PressureReplies.cleaned(older), PressureReplies.cleaned(newer)], "\(provider)")
            for row in rows {
                let evidence = try await store.dictationSource(for: row.id)
                if row.transcription == PressureReplies.cleaned(older) {
                    XCTAssertEqual(evidence?.disposition, .staleSkipped, "\(provider)")
                    XCTAssertNil(evidence?.insertedText, "\(provider)")
                    XCTAssertEqual(evidence?.recognizerText, older)
                } else {
                    XCTAssertEqual(evidence?.disposition, .pasteSent, "\(provider)")
                    XCTAssertEqual(evidence?.recognizerText, newer)
                }
            }
        }
    }
}
