import Foundation
import GRDB
import XCTest
@testable import OpenSuperWhisper

/// A speaker who restarts says the same words twice: "I can't. I can't make
/// it on Friday, um, sorry." Parakeet writes the restart with a comma or a
/// period, and the sources below are its own output for synthetic speech. A
/// cleanup that keeps one take used to read as a dropped negation, question,
/// or percent, so the whole dictation fell back to the recognizer's words,
/// every "um" and "uh" included. One take is now enough, and every other
/// check still applies.
final class RepeatedTakeGuardTests: XCTestCase {
    private func accepts(
        _ cleaned: String,
        source: String,
        mode: CleanupMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            try? CleanupGuard.postprocess(cleaned, source: source, mode: mode, allowsNumberFormatting: mode.formatsNumbers),
            cleaned,
            "Refused \(cleaned) for \(source) in \(mode)",
            file: file,
            line: line
        )
    }

    private func rejects(
        _ cleaned: String,
        source: String,
        mode: CleanupMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CleanupGuard.postprocess(cleaned, source: source, mode: mode, allowsNumberFormatting: mode.formatsNumbers),
            "Accepted \(cleaned) for \(source) in \(mode)",
            file: file,
            line: line
        )
    }

    /// Restarts and the cleanup that keeps one take.
    static let restarts: [(source: String, cleaned: String)] = [
        ("I can't. I can't make it on Friday, um, sorry.", "I can't make it on Friday, sorry."),
        ("I can't, I can't make it on Friday, um, sorry.", "I can't make it on Friday, sorry."),
        ("We don't, um, we don't need the second server.", "We don't need the second server."),
        ("I don't, I don't think we should merge it yet.", "I don't think we should merge it yet."),
        ("It's not, um, it's not ready, and it's not tested either.", "It's not ready, and it's not tested either."),
        ("What's the, what's the status of the deploy?", "What's the status of the deploy?"),
        ("Why is, uh, why is the build failing on main?", "Why is the build failing on main?"),
        ("How do we, how do we roll this back if the migration fails?", "How do we roll this back if the migration fails?"),
        ("Should we? Should we ship it today?", "Should we ship it today?"),
        ("Revenue is up 15%, uh, 15% this quarter.", "Revenue is up 15% this quarter."),
        ("Revenue is up fifteen percent, uh, fifteen percent this quarter.", "Revenue is up fifteen percent this quarter."),
        ("It was negative four, negative four degrees.", "It was negative four degrees."),
    ]

    func testCleanupThatKeepsOneTakeIsAcceptedInEveryMode() {
        for mode in CleanupMode.allCases {
            for restart in Self.restarts {
                accepts(restart.cleaned, source: restart.source, mode: mode)
            }
        }
    }

    func testCleanupThatKeepsBothTakesIsStillAccepted() {
        for mode in CleanupMode.allCases {
            accepts("I can't. I can't make it on Friday, sorry.", source: "I can't. I can't make it on Friday, um, sorry.", mode: mode)
            accepts("What's the, what's the status of the deploy?", source: "What's the, what's the status of the deploy?", mode: mode)
            accepts("Revenue is up 15%, 15% this quarter.", source: "Revenue is up 15%, uh, 15% this quarter.", mode: mode)
        }
    }

    func testARestartNeverExcusesADroppedNegation() {
        for mode in CleanupMode.allCases {
            rejects("I can make it on Friday, sorry.", source: "I can't. I can't make it on Friday, um, sorry.", mode: mode)
            rejects("We need the second server.", source: "We don't, um, we don't need the second server.", mode: mode)
            // A second, different negation is still required.
            rejects("It's not ready, and it's tested.", source: "It's not, um, it's not ready, and it's not tested either.", mode: mode)
            rejects("I like it and I don't want it.", source: "I don't like it and I don't want it.", mode: mode)
            // A filler between different words is not a restart or a correction.
            rejects("I think so.", source: "I don't, uh, think so.", mode: mode)
            rejects("I don't think so, and I'm sure.", source: "I don't think so, and I'm not, I'm not sure.", mode: mode)
            // The first "no" answers, so the second is the only negation.
            rejects("We said meetings on Friday.", source: "We said no, we said no meetings on Friday.", mode: mode)
        }
    }

    func testARestartNeverExcusesADroppedOrAnsweredQuestion() {
        for mode in CleanupMode.allCases {
            rejects("The capital of France is Paris.", source: "What's the, what's the capital of France?", mode: mode)
            rejects("The build is failing on main because a dependency is missing.", source: "Why is, uh, why is the build failing on main?", mode: mode)
            // The third "why" asks a second question.
            rejects("Why is it failing, and is it slow?", source: "Why is, why is it failing, and why is it slow?", mode: mode)
            rejects("We should ship it today.", source: "Should we? Should we ship it today?", mode: mode)
            // The first "what" does not ask, so the second is the only question.
            rejects("I know the plan.", source: "I know what is, what is the plan?", mode: mode)
        }
    }

    func testARestartNeverExcusesADroppedOrAddedSymbol() {
        for mode in CleanupMode.allCases {
            rejects("Revenue is up 15 this quarter.", source: "Revenue is up 15%, uh, 15% this quarter.", mode: mode)
            rejects("It was four degrees.", source: "It was negative four, negative four degrees.", mode: mode)
            // The first take had no percent, so the one the speaker added is required.
            rejects("Revenue is up 15 this quarter.", source: "Revenue is up 15, uh, 15% this quarter.", mode: mode)
            rejects("Up 15% last year and this year.", source: "Up 15% last year and 15%, uh, 15% this year.", mode: mode)
        }
    }

    func testARestartNeverExcusesADroppedNumber() {
        for mode in CleanupMode.allCases {
            rejects("Pick three and four from the menu.", source: "Pick two, uh, three, and four from the menu.", mode: mode)
            rejects("Book a table for people.", source: "Book a table for six, six people.", mode: mode)
        }
    }
}

/// Restarted dictations followed through the shipped finish path: the
/// indicator's transcription result, the cleanup pipeline, Bedrock over a
/// scripted Converse transport, the guard, History, and the delivered text.
/// The replies are scripted, so this proves the plumbing and the guard, not
/// how Nova Micro or any other model cleans up.
@MainActor
final class RepeatedTakeDictationTests: XCTestCase {
    private final class Speech: TranscriptionEngine {
        let isModelLoaded = true
        let engineName = "Scripted speech"
        var spoken: [URL: String] = [:]
        func initialize() async throws {}
        func getSupportedLanguages() -> [String] { ["en"] }
        func cancelTranscription() {}
        func transcribeAudio(url: URL, settings: OpenSuperWhisper.Settings) async throws -> String { spoken[url] ?? "" }
    }

    private let speech = Speech()
    private let gate = LatestDictationGate()
    private var store: RecordingStore!
    private var session: URLSession!
    private var indicator: IndicatorViewModel!
    private var delivered: [String] = []
    private var failures: [String?] = []
    private var audio: [URL] = []
    private var mode: CleanupMode = .everyday
    /// Replies to each transcript the provider receives.
    private var reply: (String) -> (status: Int, text: String) = { (200, $0) }
    private var requests = 0

    override func setUp() async throws {
        try await super.setUp()
        store = try RecordingStore(
            database: DatabaseQueue(), recordingsDirectory: Recording.recordingsDirectory,
            cancelQueuedRecording: { _ in }, stopPlayback: { _ in }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CleanupURLProtocol.self]
        session = URLSession(configuration: configuration)
        CleanupURLProtocol.handler = { [unowned self] request in
            requests += 1
            let transcript = try Self.transcript(in: request)
            let (status, text) = reply(transcript)
            let body = try JSONSerialization.data(withJSONObject: [
                "output": ["message": ["content": [["text": text]]]],
                "stopReason": "end_turn",
                "usage": ["inputTokens": 480, "outputTokens": 30],
            ])
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
        }
        let service = BedrockCleanupService(session: session)
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { true },
            providerResolver: {
                BedrockCleanupProvider(service: service, apiKey: "synthetic-test-key", configuration: .init())
            },
            vocabularyProvider: { [] }, appRuleProvider: { _ in nil }, bedrockBudgetProvider: { nil },
            filterProvider: { [unowned self] in .builtIn(mode) }, autoConfigProvider: { nil },
            failureRecorder: { [unowned self] in failures.append($0) }
        )
        indicator = IndicatorViewModel(
            latestDictationGate: gate, transcriptionService: TranscriptionService(engine: speech),
            recordingStore: store, cleanupPipeline: pipeline,
            delivery: { [unowned self] in delivered.append($0); return .pasteSent }
        )
    }

    override func tearDown() async throws {
        indicator.cleanup()
        session.invalidateAndCancel()
        CleanupURLProtocol.handler = nil
        for url in audio { try? FileManager.default.removeItem(at: url) }
        try await super.tearDown()
    }

    private static func transcript(in request: URLRequest) throws -> String {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
                body.append(buffer, count: count)
            }
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let user = try XCTUnwrap(content.first?["text"] as? String)
        let start = try XCTUnwrap(user.range(of: "<transcript>\n"))
        let end = try XCTUnwrap(user.range(of: "\n</transcript>", options: .backwards))
        return String(user[start.upperBound..<end.lowerBound])
    }

    /// Dictates the words and returns what was pasted and the History row.
    private func dictate(_ words: String) async throws -> (pasted: String?, row: Recording) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RepeatedTake-\(UUID().uuidString).wav")
        try Data("synthetic audio".utf8).write(to: url)
        speech.spoken[url] = words
        let before = delivered.count
        await indicator.finishDictation(audioAt: url, generation: gate.begin(), recordingStartedAt: Date())
        var rows: [Recording] = []
        for _ in 0..<300 {
            rows = try await store.fetchRecordings(limit: 50, offset: 0)
            if rows.contains(where: { !audio.contains($0.url) }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let row = try XCTUnwrap(rows.first { !audio.contains($0.url) }, "History saved “\(words)”")
        audio.append(row.url)
        return (delivered.count > before ? delivered.last : nil, row)
    }

    private static let hesitation = try! NSRegularExpression(pattern: #"\b(?:um|uh)\b"#, options: [.caseInsensitive])

    private static func hesitations(in text: String) -> Int {
        hesitation.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Homework writes the cleanup's quantities as digits afterward.
    private static func finished(_ cleaned: String, source: String, mode: CleanupMode) -> String {
        guard mode == .homework else { return cleaned }
        let formatted = HomeworkNumberFormatter.format(cleaned)
        return (try? CleanupGuard.postprocess(formatted, source: source, mode: mode, allowsNumberFormatting: true)) ?? cleaned
    }

    func testRestartedDictationsArePastedCleanedInEveryMode() async throws {
        for mode in CleanupMode.allCases {
            self.mode = mode
            for restart in RepeatedTakeGuardTests.restarts {
                reply = { _ in (200, restart.cleaned) }
                let (pasted, row) = try await dictate(restart.source)
                let expected = Self.finished(restart.cleaned, source: restart.source, mode: mode)
                XCTAssertEqual(pasted, expected, "\(mode): \(restart.source)")
                XCTAssertEqual(row.transcription, expected)
                XCTAssertEqual(row.cleanupSource, .bedrock)
                XCTAssertEqual(Self.hesitations(in: pasted ?? "um"), 0)
            }
        }
        XCTAssertEqual(failures.compactMap { $0 }, [], "No cleanup failed")
    }

    func testUnsafeRepliesAndProviderFailuresStillKeepTheRecognizerWords() async throws {
        let source = "I can't. I can't make it on Friday, um, sorry."
        let replies: [(status: Int, text: String)] = [
            (200, "I can make it on Friday, sorry."),
            (200, "Sure, I'll let them know you can't make it on Friday."),
            (503, ""),
        ]
        for mode in CleanupMode.allCases {
            self.mode = mode
            for unsafe in replies {
                failures = []
                reply = { _ in unsafe }
                let (pasted, row) = try await dictate(source)
                XCTAssertEqual(pasted, source, "\(mode): \(unsafe.text)")
                XCTAssertEqual(row.cleanupSource, .rawFallback)
                XCTAssertEqual(failures.compactMap { $0 }, [TranscriptCleanupPipeline.safeFailureMessage])
            }
        }
    }

    func testOneRestartNoLongerCostsALongDictationItsCleanup() async throws {
        // Over the 4,800-character chunk limit, so it takes several requests.
        let paragraph = "Um, so for the launch plan, uh, we should move the review to Thursday and, um, send the draft to Priya first. "
        var source = ""
        while source.count < 5_200 { source += paragraph }
        source += "I can't. I can't make it on Friday, um, sorry."
        XCTAssertGreaterThan(TranscriptChunker.chunks(source).count, 1)
        // A model that drops hesitation sounds and keeps one take of the restart.
        reply = { transcript in
            let text = transcript
                .replacingOccurrences(of: #"(?i)\b(?:um|uh)\b,?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "I can't. I can't", with: "I can't")
            return (200, text)
        }
        mode = .writing
        requests = 0
        let (pasted, row) = try await dictate(source)
        let text = try XCTUnwrap(pasted)
        XCTAssertEqual(row.cleanupSource, .bedrock)
        XCTAssertEqual(requests, TranscriptChunker.chunks(source).count)
        XCTAssertGreaterThan(Self.hesitations(in: source), 100)
        XCTAssertEqual(Self.hesitations(in: text), 0)
        XCTAssertTrue(text.hasSuffix("I can't make it on Friday, sorry."))
    }
}
