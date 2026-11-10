import AVFoundation
import Darwin
import FluidAudio
import GRDB
import XCTest
@testable import OpenSuperWhisper

/// Opt-in latency and accuracy benchmark for the dictation path after the
/// key is released. It runs the cached Parakeet v3 model on known-transcript
/// audio files and writes one JSON line per measured call. It skips unless
/// `WF_BENCH_CORPUS` (passed to xcodebuild as `TEST_RUNNER_WF_BENCH_CORPUS`)
/// names a folder of 16 kHz WAV files. No microphone, playback, provider,
/// pasteboard, or keystroke is used.
@MainActor
final class DictationLatencyBenchmarkTests: XCTestCase {
    private struct Sample: Encodable {
        let cell: String
        let fixture: String
        let iteration: Int
        let audioSeconds: Double
        let wallSeconds: Double
        let cpuSeconds: Double
        let rssBytes: UInt64
        let text: String
        let stages: [String: Double]
    }

    private var corpus: URL!
    private var output: FileHandle?
    private var iterations = 5

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WF_BENCH_CORPUS"] else {
            throw XCTSkip("Set TEST_RUNNER_WF_BENCH_CORPUS to run the dictation benchmark")
        }
        corpus = URL(fileURLWithPath: path)
        iterations = Int(environment["WF_BENCH_ITERATIONS"] ?? "") ?? 5
        let outURL = URL(fileURLWithPath: environment["WF_BENCH_OUT"] ?? path)
            .appendingPathComponent("bench-\(environment["WF_BENCH_LABEL"] ?? "run").jsonl")
        if !FileManager.default.fileExists(atPath: outURL.path) {
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
        }
        output = try FileHandle(forWritingTo: outURL)
        output?.seekToEndOfFile()
    }

    override func tearDown() {
        try? output?.close()
        output = nil
    }

    private func fixtures() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func write(_ sample: Sample) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(sample) else { return }
        data.append(0x0A)
        output?.write(data)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func residentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func prepareEngine() async throws -> (FluidAudioEngine, Double) {
        let modelDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDirectory.path), "Cached Parakeet v3 is required")
        let prefs = AppPreferences.shared
        prefs.selectedEngine = "fluidaudio"
        prefs.fluidAudioModelVersion = "v3"
        prefs.whisperLanguage = "en"
        let start = ContinuousClock.now
        let engine = FluidAudioEngine()
        try await engine.initialize()
        return (engine, Self.seconds(start.duration(to: .now)))
    }

    /// Recognition alone: the engine call the coordinator makes, on a file.
    func testRecognitionLatency() async throws {
        let files = try fixtures()
        let (engine, loadSeconds) = try await prepareEngine()
        write(Sample(cell: "engine-load", fixture: "-", iteration: 0, audioSeconds: 0, wallSeconds: loadSeconds,
                     cpuSeconds: 0, rssBytes: Self.residentBytes(), text: "", stages: [:]))
        // Interleaved: every iteration visits every fixture once.
        for iteration in 0..<iterations {
            for file in files {
                let audioSeconds = await AudioUtil.audioDuration(url: file)
                let cpuBefore = Self.cpuSeconds()
                let start = ContinuousClock.now
                let text = try await engine.transcribeAudio(url: file, settings: Settings())
                let wall = Self.seconds(start.duration(to: .now))
                write(Sample(cell: iteration == 0 ? "recognize-first" : "recognize-warm",
                             fixture: file.deletingPathExtension().lastPathComponent, iteration: iteration,
                             audioSeconds: audioSeconds, wallSeconds: wall, cpuSeconds: Self.cpuSeconds() - cpuBefore,
                             rssBytes: Self.residentBytes(), text: text, stages: [:]))
            }
        }
    }

    /// The read-only device queries the recorder makes before every
    /// recording starts. Nothing here opens the microphone.
    func testCaptureStartQueries() throws {
        let service = MicrophoneService.shared
        guard let mic = service.getActiveMicrophone() else { throw XCTSkip("No input device") }
        for iteration in 0..<max(iterations, 1) {
            var stages: [String: Double] = [:]
            func time(_ name: String, _ body: () -> Void) {
                let start = ContinuousClock.now
                body()
                stages[name] = Self.seconds(start.duration(to: .now))
            }
            time("requiresConnection") { _ = service.isActiveMicrophoneRequiresConnection() }
            time("coreAudioID") { _ = service.getCoreAudioDeviceID(for: mic) }
            time("currentDefault") { _ = service.getCurrentSystemDefaultInputDevice() }
            time("channelCount") { _ = service.getInputChannelCount(for: mic) }
            time("configuration") { _ = MicrophoneCaptureConfiguration.forNextRecording(.dictation) }
            write(Sample(cell: "capture-queries", fixture: "builtin", iteration: iteration, audioSeconds: 0,
                         wallSeconds: stages.values.reduce(0, +), cpuSeconds: 0, rssBytes: 0, text: "", stages: stages))
        }
    }

    /// The coordinator's steps one at a time, to place its wait.
    func testCoordinatorStages() async throws {
        let files = try fixtures()
        let (engine, _) = try await prepareEngine()
        let service = TranscriptionService(engine: engine)
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { false },
            providerResolver: { throw CleanupProviderError.missingCredential("none") },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { nil },
            filterProvider: { .builtIn(.everyday) },
            failureRecorder: { _ in }
        )
        for iteration in 0..<iterations {
            for file in files {
                let t0 = ContinuousClock.now
                let audioSeconds = await AudioUtil.audioDuration(url: file)
                let t1 = ContinuousClock.now
                let raw = try await service.transcribeAudio(url: file, settings: Settings())
                let t2 = ContinuousClock.now
                let direct = try await engine.transcribeAudio(url: file, settings: Settings())
                let t3 = ContinuousClock.now
                let cleanup = await pipeline.finalize(raw, targetBundleID: nil, filterPlan: pipeline.selectedPlan())
                let t4 = ContinuousClock.now
                XCTAssertEqual(raw, direct)
                write(Sample(cell: "stages", fixture: file.deletingPathExtension().lastPathComponent,
                             iteration: iteration, audioSeconds: audioSeconds,
                             wallSeconds: Self.seconds(t0.duration(to: t4)), cpuSeconds: 0, rssBytes: Self.residentBytes(),
                             text: cleanup.text,
                             stages: ["duration": Self.seconds(t0.duration(to: t1)),
                                      "service": Self.seconds(t1.duration(to: t2)),
                                      "engineDirect": Self.seconds(t2.duration(to: t3)),
                                      "finalize": Self.seconds(t3.duration(to: t4))]))
            }
        }
    }

    /// Stop to delivered text through the production coordinator, with cleanup
    /// off and a delivery stub in place of the paste.
    func testCoordinatorLatency() async throws {
        let files = try fixtures()
        let (engine, _) = try await prepareEngine()
        let service = TranscriptionService(engine: engine)
        let store = try RecordingStore(
            database: DatabaseQueue(),
            recordingsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkFlowBench-\(UUID().uuidString)"),
            cancelQueuedRecording: { _ in },
            stopPlayback: { _ in }
        )
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { false },
            providerResolver: { throw CleanupProviderError.missingCredential("none") },
            vocabularyProvider: { [] },
            appRuleProvider: { _ in nil },
            bedrockBudgetProvider: { nil },
            filterProvider: { .builtIn(.everyday) },
            failureRecorder: { _ in }
        )
        let gate = LatestDictationGate()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("WorkFlowBenchAudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        for iteration in 0..<iterations {
            for file in files {
                let copy = scratch.appendingPathComponent(UUID().uuidString + ".wav")
                try FileManager.default.copyItem(at: file, to: copy)
                var delivered: (text: String, at: ContinuousClock.Instant)?
                let viewModel = IndicatorViewModel(
                    latestDictationGate: gate,
                    transcriptionService: service,
                    recordingStore: store,
                    cleanupPipeline: pipeline,
                    delivery: { text in
                        delivered = (text, .now)
                        return .pasteSent
                    }
                )
                let audioSeconds = await AudioUtil.audioDuration(url: file)
                let cpuBefore = Self.cpuSeconds()
                let stoppedAt = ContinuousClock.now
                await viewModel.finishDictation(audioAt: copy, generation: gate.begin(), recordingStartedAt: Date(),
                                                stoppedAt: stoppedAt)
                let returned = ContinuousClock.now
                viewModel.cleanup()
                write(Sample(cell: iteration == 0 ? "coordinator-first" : "coordinator-warm",
                             fixture: file.deletingPathExtension().lastPathComponent, iteration: iteration,
                             audioSeconds: audioSeconds,
                             wallSeconds: Self.seconds(stoppedAt.duration(to: delivered?.at ?? returned)),
                             cpuSeconds: Self.cpuSeconds() - cpuBefore, rssBytes: Self.residentBytes(),
                             text: delivered?.text ?? "",
                             stages: ["returned": Self.seconds(stoppedAt.duration(to: returned))]))
            }
        }
    }
}

/// Long-form accuracy: FluidAudio's batch path, its sliding window, and
/// WorkFlow's segmenter feeding the single-window path, on the same files.
@MainActor
final class LongFormPathComparisonTests: XCTestCase {
    private struct Row: Encodable {
        let fixture: String
        let path: String
        let audioSeconds: Double
        let seconds: Double
        let pieces: Int
        let text: String
    }

    func testPathsOnSameFiles() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WF_BENCH_CORPUS"] else { throw XCTSkip("Set TEST_RUNNER_WF_BENCH_CORPUS") }
        let paths = (environment["WF_BENCH_VARIANTS"] ?? "batch,segmented,sliding").split(separator: ",").map(String.init)
        let out = URL(fileURLWithPath: environment["WF_BENCH_OUT"] ?? path)
            .appendingPathComponent("paths-\(environment["WF_BENCH_LABEL"] ?? "run").jsonl")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        AppPreferences.shared.fluidAudioModelVersion = "v3"
        AppPreferences.shared.whisperLanguage = "en"
        let engine = FluidAudioEngine()
        try await engine.initialize()
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let samples = try AudioConverter().resampleAudioFile(file)
            for variant in paths {
                let start = ContinuousClock.now
                var text = ""
                let pieceCount = 1
                switch variant {
                case "batch":
                    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                    text = try await manager.transcribe(file, decoderState: &state, language: .english).text
                case "segmented":
                    text = try await engine.transcribeAudio(url: file, settings: Settings())
                case let name where name.hasPrefix("seg"):
                    // seg<minimum>-<maximum>, for example seg4-14
                    let bounds = name.dropFirst(3).split(separator: "-").compactMap { Double($0) }
                    let transcriber = SegmentedTranscriber(
                        segmenter: SpeechSegmenter(minimumSeconds: bounds[0], maximumSeconds: bounds[1])
                    ) { piece, _ in
                        var chunk = piece
                        if chunk.count < 4_800 { chunk += [Float](repeating: 0, count: 4_800 - chunk.count) }
                        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                        return try await manager.transcribe(chunk, decoderState: &state, language: .english).text
                    }
                    try await transcriber.append(samples)
                    text = try await transcriber.finish()
                default:
                    let live = SlidingWindowAsrManager(config: SlidingWindowAsrConfig.default.applying(language: .english))
                    try await live.loadModels(models)
                    try await live.startStreaming()
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
                    var offset = 0
                    while offset < samples.count {
                        let count = min(1_600, samples.count - offset)
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                        buffer.frameLength = AVAudioFrameCount(count)
                        samples.withUnsafeBufferPointer { source in
                            buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
                        }
                        await live.streamAudio(buffer)
                        offset += count
                    }
                    text = try await live.finish()
                    await live.cleanup()
                }
                let elapsed = start.duration(to: .now)
                let row = Row(fixture: file.deletingPathExtension().lastPathComponent, path: variant,
                              audioSeconds: Double(samples.count) / 16_000,
                              seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                              pieces: pieceCount, text: text)
                var data = try JSONEncoder().encode(row)
                data.append(0x0A)
                handle.write(data)
            }
        }
    }
}

/// Live recognition through the production coordinator: each fixture is
/// written into a WAV at 1x speed through AVAudioFile, the recorder's own file
/// writer, while the dictation's live recognition follows it; the clock runs
/// from the file closing (the recorder's stop) to the text being delivered.
@MainActor
final class LiveDictationBenchmarkTests: XCTestCase {
    private struct Row: Encodable {
        let fixture: String
        let cell: String
        let iteration: Int
        let audioSeconds: Double
        let closeToDeliveredSeconds: Double
        let cpuSeconds: Double
        let text: String
        let offlineText: String
        let fallback: String
    }

    func testLiveCoordinatorAtRealTime() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WF_BENCH_CORPUS"] else { throw XCTSkip("Set TEST_RUNNER_WF_BENCH_CORPUS") }
        let iterations = Int(environment["WF_BENCH_ITERATIONS"] ?? "") ?? 1
        let speed = Double(environment["WF_BENCH_SPEED"] ?? "") ?? 1
        let out = URL(fileURLWithPath: environment["WF_BENCH_OUT"] ?? path)
            .appendingPathComponent("livecoord-\(environment["WF_BENCH_LABEL"] ?? "run").jsonl")
        if !FileManager.default.fileExists(atPath: out.path) { FileManager.default.createFile(atPath: out.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: out)
        handle.seekToEndOfFile()
        defer { try? handle.close() }

        AppPreferences.shared.selectedEngine = "fluidaudio"
        AppPreferences.shared.fluidAudioModelVersion = "v3"
        AppPreferences.shared.whisperLanguage = "en"
        let engine = FluidAudioEngine()
        try await engine.initialize()
        let service = TranscriptionService(engine: engine)
        let store = try RecordingStore(
            database: DatabaseQueue(),
            recordingsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("WorkFlowBench-\(UUID().uuidString)"),
            cancelQueuedRecording: { _ in }, stopPlayback: { _ in }
        )
        let pipeline = TranscriptCleanupPipeline(
            isEnabled: { false }, providerResolver: { throw CleanupProviderError.missingCredential("none") },
            vocabularyProvider: { [] }, appRuleProvider: { _ in nil }, bedrockBudgetProvider: { nil },
            filterProvider: { .builtIn(.everyday) }, failureRecorder: { _ in }
        )
        let gate = LatestDictationGate()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("WorkFlowLiveBench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for iteration in 0..<iterations {
            for file in files {
                // live: recorded at real time with live recognition; paced: the same
                // recording without it; offline: the finished file only.
                let cells = (environment["WF_BENCH_CELLS"] ?? "live,offline").split(separator: ",").map(String.init)
                for cell in cells {
                    let source = try AVAudioFile(forReading: file)
                    let recording = scratch.appendingPathComponent(UUID().uuidString + ".wav")
                    var live: LiveTranscription?
                    let cpuBefore = Self.cpuSeconds()
                    if cell == "live" {
                        try await Self.record(source, to: recording, speed: speed) {
                            live = service.beginLiveTranscription(audioAt: recording, settings: Settings())
                        }
                    } else if cell == "paced" {
                        try await Self.record(source, to: recording, speed: speed) {}
                    } else {
                        try await Self.record(source, to: recording, speed: .infinity) {}
                    }
                    var delivered: (String, ContinuousClock.Instant)?
                    let viewModel = IndicatorViewModel(
                        latestDictationGate: gate, transcriptionService: service, recordingStore: store,
                        cleanupPipeline: pipeline, delivery: { text in
                            delivered = (text, .now)
                            return .pasteSent
                        }
                    )
                    let closed = ContinuousClock.now
                    await viewModel.finishDictation(audioAt: recording, generation: gate.begin(), recordingStartedAt: Date(),
                                                    stoppedAt: closed, live: live)
                    let end = delivered?.1 ?? .now
                    viewModel.cleanup()
                    let fallback = await live?.fallback.map { "\($0)" } ?? ""
                    let copy = scratch.appendingPathComponent(UUID().uuidString + ".wav")
                    try FileManager.default.copyItem(at: file, to: copy)
                    let offline = try await engine.transcribeAudio(url: copy, settings: Settings())
                    let row = Row(
                        fixture: file.deletingPathExtension().lastPathComponent, cell: cell, iteration: iteration,
                        audioSeconds: Double(source.length) / source.processingFormat.sampleRate,
                        closeToDeliveredSeconds: Self.seconds(closed.duration(to: end)),
                        cpuSeconds: Self.cpuSeconds() - cpuBefore,
                        text: delivered?.0 ?? "", offlineText: offline, fallback: fallback
                    )
                    var data = try JSONEncoder().encode(row)
                    data.append(0x0A)
                    handle.write(data)
                }
            }
        }
    }

    /// Writes `source` into a 16-bit mono 16 kHz WAV as a recorder would, in
    /// 100 ms buffers paced at `speed` times real time.
    static func record(_ source: AVAudioFile, to url: URL, speed: Double, started: @escaping () -> Void) async throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
        ]
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        started()
        let format = source.processingFormat
        let block = AVAudioFrameCount(format.sampleRate / 10)
        let begin = ContinuousClock.now
        var written: AVAudioFramePosition = 0
        while source.framePosition < source.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else { break }
            try source.read(into: buffer, frameCount: block)
            if buffer.frameLength == 0 { break }
            try writer?.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
            if speed.isFinite {
                let due = begin + .milliseconds(Int(Double(written) / format.sampleRate / speed * 1000))
                try await Task.sleep(until: due, clock: .continuous)
            }
        }
        writer = nil
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
