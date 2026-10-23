import AVFoundation
import CoreAudio
import os
import UniformTypeIdentifiers
import XCTest
@testable import OpenSuperWhisper

/// Word and OpenDocument types are declared by macOS, so the importer looks
/// them up instead of importing them; it reads the same files as before.
final class DocumentTypeLookupTests: XCTestCase {
    func testWordAndOpenDocumentTypesAreTheSystemDeclarations() throws {
        for (fileExtension, identifier) in [
            ("docx", "org.openxmlformats.wordprocessingml.document"),
            ("doc", "com.microsoft.word.doc"),
            ("odt", "org.oasis-open.opendocument.text")
        ] {
            let type = try XCTUnwrap(UTType(filenameExtension: fileExtension))
            XCTAssertEqual(type.identifier, identifier)
            XCTAssertTrue(type.isDeclared && !type.isDynamic, "\(identifier) is declared by the system")
            XCTAssertTrue(DocumentTextExtractor.supportedTypes.contains(type), "\(fileExtension) stays supported")
            XCTAssertTrue(DocumentTextExtractor.isSupported(URL(fileURLWithPath: "/tmp/finished.\(fileExtension)")))
        }
        XCTAssertEqual(DocumentTextExtractor.supportedTypes.count, 7, "No document type is added or lost")
    }
}

/// Reads CoreAudio's device list only: nothing records, and no privacy prompt
/// or window appears.
final class CoreAudioDeviceLookupTests: XCTestCase {
    private func uid(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func device(_ id: String) -> MicrophoneService.AudioDevice {
        MicrophoneService.AudioDevice(id: id, name: "Fixture", manufacturer: nil, isBuiltIn: false)
    }

    func testDeviceUIDsTranslateToTheirCoreAudioDevices() throws {
        let service = MicrophoneService.shared
        // An unknown UID matches no device; CoreAudio answers kAudioObjectUnknown.
        let unknown = service.getCoreAudioDeviceID(for: device("WorkFlow.unknown.\(UUID().uuidString)"))
        XCTAssertEqual(unknown ?? AudioDeviceID(kAudioObjectUnknown), AudioDeviceID(kAudioObjectUnknown))

        service.refreshAvailableMicrophones()
        var translated = 0
        for microphone in service.availableMicrophones {
            guard let deviceID = service.getCoreAudioDeviceID(for: microphone) else { continue }
            XCTAssertEqual(uid(of: deviceID), microphone.id, "\(microphone.name) round-trips")
            translated += 1
        }
        print("COREAUDIO_LOOKUP enumerated=\(service.availableMicrophones.count) translated=\(translated)")

        guard let defaultInput = service.getCurrentSystemDefaultInputDevice() else {
            throw XCTSkip("This Mac has no default input device")
        }
        let defaultUID = try XCTUnwrap(uid(of: defaultInput))
        XCTAssertEqual(service.getCoreAudioDeviceID(for: device(defaultUID)), defaultInput)
    }
}

/// The bundled 11 s, 16 kHz reference recording takes the parallel
/// conversion path with no resampling, so its samples are exact.
final class WhisperConversionFingerprintTests: XCTestCase {
    private static let reference = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("jfk.wav")

    func testRealRecordingConvertsCompletely() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.reference.path))
        let converted = try await WhisperEngine().convertAudioToPCM(fileURL: Self.reference)
        let samples = try XCTUnwrap(converted)
        XCTAssertEqual(samples.count, 176_000)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for sample in samples {
            hash = (hash ^ UInt64(sample.bitPattern)) &* 0x0000_0100_0000_01b3
        }
        print("WHISPER_CONVERSION count=\(samples.count) fnv1a=\(String(hash, radix: 16))")

        // The parallel path, now awaited instead of blocking, matches one pass exactly.
        let file = try AVAudioFile(forReading: Self.reference)
        let target = try XCTUnwrap(WhisperEngine().makeTargetFormat(channelCount: file.processingFormat.channelCount))
        let onePass = try WhisperEngine.convertSegment(
            fileURL: Self.reference,
            sourceFormat: file.processingFormat,
            targetFormat: target,
            ratio: target.sampleRate / file.processingFormat.sampleRate,
            startFrame: 0,
            frameCount: file.length,
            inputChunkSize: 1_048_576
        )
        XCTAssertEqual(samples, onePass)
    }
}

/// Whisper's C progress callback still reaches the app on the main queue,
/// in order, through the Sendable progress context. Uses the repository's
/// tiny model and reference recording; nothing records.
final class WhisperProgressCallbackTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func testTranscriptionReportsOrderedProgressOnTheMainQueue() async throws {
        let model = Self.root.appendingPathComponent("ggml-tiny.en.bin")
        let audio = Self.root.appendingPathComponent("jfk.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model.path) && FileManager.default.fileExists(atPath: audio.path))
        // Four takes of the reference span two 30 s windows, so whisper reports
        // progress between them.
        let source = try AVAudioFile(forReading: audio)
        let take = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)))
        try source.read(into: take)
        let long = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperProgress-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: long) }
        do {
            let output = try AVAudioFile(forWriting: long, settings: source.fileFormat.settings)
            for _ in 0..<4 { try output.write(from: take) }
        }

        let engine = WhisperEngine()
        try engine.load(modelPath: model.path)
        let reports = OSAllocatedUnfairLock(initialState: [(progress: Float, onMain: Bool)]())
        engine.onProgressUpdate = { progress in
            reports.withLock { $0.append((progress, Thread.isMainThread)) }
        }

        let text = try await engine.transcribeAudio(url: long, settings: OpenSuperWhisper.Settings())
        for _ in 0..<50 { try await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertTrue(text.lowercased().contains("country"), text)
        let received = reports.withLock { $0 }
        let fromWhisper = received.filter { $0.progress > 0.10 && $0.progress <= 0.95 }
        print("WHISPER_PROGRESS reports=\(received.map { String(format: "%.3f", $0.progress) }) fromCallback=\(fromWhisper.count)")
        XCTAssertFalse(fromWhisper.isEmpty, "Whisper's own progress reached the app")
        XCTAssertTrue(fromWhisper.allSatisfy(\.onMain), "Callback reports arrive on the main queue")
        XCTAssertEqual(fromWhisper.map(\.progress), fromWhisper.map(\.progress).sorted(), "Reports only move forward")
    }
}
