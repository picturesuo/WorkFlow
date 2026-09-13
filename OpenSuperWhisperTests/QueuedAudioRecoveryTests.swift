import XCTest
@testable import OpenSuperWhisper

final class QueuedAudioRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-queue-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testInterruptedRelocationRecoversExactSavedAudioWithoutDeletingIt() throws {
        let oldSource = directory.appendingPathComponent("temporary.wav")
        let savedAudio = directory.appendingPathComponent("owned.wav")
        let audio = Data("fixture audio".utf8)
        try audio.write(to: oldSource)
        // Reproduce persisted pending sourceFileURL after a completed file move,
        // before its database update or cleanup finishes.
        try FileManager.default.moveItem(at: oldSource, to: savedAudio)

        let recovered = TranscriptionQueue.recoverPendingAudioSource(
            sourceURL: oldSource, savedAudioURL: savedAudio
        )

        XCTAssertEqual(recovered, savedAudio)
        XCTAssertEqual(try Data(contentsOf: savedAudio), audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSource.path))
    }

    func testExistingSourceRemainsCanonicalWhenBothPathsExist() throws {
        let source = directory.appendingPathComponent("import.wav")
        let saved = directory.appendingPathComponent("owned.wav")
        try Data("original import".utf8).write(to: source)
        try Data("older saved audio".utf8).write(to: saved)
        XCTAssertEqual(
            TranscriptionQueue.recoverPendingAudioSource(sourceURL: source, savedAudioURL: saved),
            source
        )
    }

    func testMissingSourceCanRecoverItsOwnedAudio() throws {
        let saved = directory.appendingPathComponent("owned.wav")
        try Data("saved".utf8).write(to: saved)
        XCTAssertEqual(
            TranscriptionQueue.recoverPendingAudioSource(sourceURL: nil, savedAudioURL: saved),
            saved
        )
    }

    func testRecoveryNeverSubstitutesUnrelatedAudio() throws {
        let unrelated = directory.appendingPathComponent("another-recording.wav")
        try Data("unrelated".utf8).write(to: unrelated)
        XCTAssertNil(TranscriptionQueue.recoverPendingAudioSource(
            sourceURL: directory.appendingPathComponent("missing-source.wav"),
            savedAudioURL: directory.appendingPathComponent("missing-owned.wav")
        ))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated".utf8))
    }
}
