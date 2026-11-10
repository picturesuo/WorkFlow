import XCTest
@testable import OpenSuperWhisper

@MainActor
final class AudioRecordingFileTests: XCTestCase {
    func testRapidSessionsHaveDistinctTemporaryAndSavedAudioPaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-audio-files-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent(AudioRecorder.recordingFileName())
        let second = directory.appendingPathComponent(AudioRecorder.recordingFileName())
        XCTAssertNotEqual(first, second)
        try Data("first session".utf8).write(to: first)
        try Data("second session".utf8).write(to: second)

        let firstID = UUID()
        let secondID = UUID()
        let saved = directory.appendingPathComponent("saved")
        let firstSaved = saved.appendingPathComponent(AudioRecorder.recordingFileName(id: firstID))
        let secondSaved = saved.appendingPathComponent(AudioRecorder.recordingFileName(id: secondID))
        try AudioRecorder.shared.moveTemporaryRecording(from: first, to: firstSaved)
        try AudioRecorder.shared.moveTemporaryRecording(from: second, to: secondSaved)

        XCTAssertEqual(try Data(contentsOf: firstSaved), Data("first session".utf8))
        XCTAssertEqual(try Data(contentsOf: secondSaved), Data("second session".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testSavingCannotOverwriteAnExistingRecording() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-audio-collision-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let incoming = directory.appendingPathComponent("incoming.wav")
        let existing = directory.appendingPathComponent("saved.wav")
        try Data("new audio".utf8).write(to: incoming)
        try Data("original audio".utf8).write(to: existing)

        XCTAssertThrowsError(try AudioRecorder.shared.moveTemporaryRecording(from: incoming, to: existing))
        XCTAssertEqual(try Data(contentsOf: existing), Data("original audio".utf8))
        XCTAssertEqual(try Data(contentsOf: incoming), Data("new audio".utf8))
    }
}
