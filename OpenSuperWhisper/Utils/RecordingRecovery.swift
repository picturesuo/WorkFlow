import AppKit
import AVFoundation
import DictationCore
import Foundation

/// Runs `RecordingRecoveryCore` at launch: recordings a WorkFlow left in the
/// temporary folder when it quit, crashed or was force-quit before they
/// reached History become failed History rows that keep their audio and
/// offer Regenerate. Nothing is transcribed, pasted or copied here, and no
/// file is ever deleted here: what is not adopted stays for the 24-hour sweep.
///
/// A recording whose process died while it was still capturing has every
/// sample on disk behind a header that declares none, because the recorder
/// fills in the sizes only when it stops. `WAVLayoutCore` finds that audio,
/// and the two size fields are rewritten in place so the engine can read it
/// on Regenerate. Those eight bytes, in a file this pass adopts, are the only
/// ones it ever writes.
@MainActor
enum RecordingRecovery {
    /// Why a recovered row has no transcript. Its description is the row's
    /// History text, shown the way every failed row's message is.
    struct ClosedBeforeTranscription: LocalizedError {
        var errorDescription: String? {
            "Recovered recording - \(AppIdentity.productName) closed before this was transcribed. Select Regenerate to transcribe it."
        }
    }

    /// The launch pass over the app's own folder and History. It runs before
    /// the temporary-file sweep, which would delete what this adopts.
    static func adoptOrphansAtLaunch() async {
        // Without the launch time, a file this process is recording cannot
        // be told from one an earlier process left.
        guard let launchedAt = PerfSignpost.processStartDate() else { return }
        let adopted = await adoptOrphans(
            in: AudioRecorder.temporaryRecordingsDirectory,
            launchedAt: launchedAt,
            store: .shared,
            cleanupPipeline: .shared,
            anotherWorkFlowIsRunning: isAnotherWorkFlowRunning,
            keepAudio: AudioRecorder.shared.keepTemporaryRecording
        )
        if adopted > 0 {
            print("Recovered \(adopted) recording(s) into History.")
        }
    }

    /// Adopts the orphaned recordings in `directory` and returns how many
    /// History rows were added. `keepAudio` moves a recording into History
    /// and returns where it is left, as for any failed dictation.
    @discardableResult
    static func adoptOrphans(
        in directory: URL,
        launchedAt: Date,
        store: RecordingStore,
        cleanupPipeline: TranscriptCleanupPipeline,
        anotherWorkFlowIsRunning: () -> Bool,
        keepAudio: (URL, URL) -> URL?
    ) async -> Int {
        // Every WorkFlow build shares the folder, so a file with no row here
        // may be one the other process is still recording or transcribing.
        guard !anotherWorkFlowIsRunning() else { return 0 }
        // If History cannot say what it references, nothing is adopted.
        guard let referenced = try? await store.referencedAudioPaths() else { return 0 }
        let minimumDuration = AudioRecorder.minimumRecordingDuration
        let scanned = await Task.detached(priority: .utility) {
            scan(directory, referenced: referenced, minimumDuration: minimumDuration)
        }.value
        let orphans = RecordingRecoveryCore.filesToAdopt(
            scanned.map(\.candidate),
            launchedAt: launchedAt,
            minimumDuration: minimumDuration
        )
        guard !orphans.isEmpty else { return 0 }
        let repairs = Dictionary(
            scanned.compactMap { file in file.repair.map { (file.candidate.url, $0) } },
            uniquingKeysWith: { first, _ in first }
        )

        // Regenerate uses the filter selected now, as for a queued recording:
        // the one selected when it was recorded is not known.
        let plan = cleanupPipeline.selectedPlan()
        let cleanupRequested = cleanupPipeline.cleanupRequested(targetBundleID: nil)
        var adopted = 0
        for orphan in orphans {
            guard let modified = orphan.modified, let duration = orphan.duration else { continue }
            if let layout = repairs[orphan.url] {
                // Only a file the core adopts is ever written to. A row whose
                // audio the engine cannot read would offer a Regenerate that fails.
                let url = orphan.url
                let repaired = await Task.detached(priority: .utility) {
                    repairHeader(of: url, layout, modified: modified)
                }.value
                guard repaired else { continue }
            }
            let saved = await store.addFailedDictation(
                audioAt: orphan.url,
                error: ClosedBeforeTranscription(),
                duration: duration,
                timestamp: modified,
                selectedFilter: plan.provisionalFilter,
                autoConfig: plan.autoConfig,
                cleanupRequested: cleanupRequested,
                targetBundleID: nil,
                recordingStartedAt: nil,
                keepAudioIfUnsaved: true,
                keepAudio: keepAudio
            )
            if saved { adopted += 1 }
        }
        return adopted
    }

    /// One file in the folder: what the core decides on, and the header
    /// repair it needs before it can be adopted, if any.
    struct ScannedFile: Sendable {
        let candidate: RecordingRecoveryCore.Candidate
        let repair: WAVLayoutCore.Layout?
    }

    /// Reads the folder: every regular file with its date, its audio length,
    /// and whether History references it. Nothing is changed.
    ///
    /// A file that reads as at least `minimumDuration` is taken as it is.
    /// One that reads shorter, or not at all, is offered to `WAVLayoutCore`:
    /// if its samples are on disk behind unfinished sizes, the audio found
    /// there is its length and the layout is the repair it needs.
    nonisolated static func scan(_ directory: URL, referenced: Set<String>, minimumDuration: TimeInterval) -> [ScannedFile] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else { return [] }
        return files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            var duration = audioDuration(of: file)
            var repair: WAVLayoutCore.Layout?
            if (duration ?? 0) < minimumDuration, let layout = unfinishedLayout(of: file), layout.duration >= minimumDuration {
                duration = layout.duration
                repair = layout
            }
            return ScannedFile(
                candidate: RecordingRecoveryCore.Candidate(
                    url: file,
                    modified: values.contentModificationDate,
                    duration: duration,
                    isReferenced: referenced.contains(file.standardizedFileURL.path)
                ),
                repair: repair
            )
        }
    }

    /// The layout of a PCM WAV file whose header sizes were never finished;
    /// nil for a file that needs no repair or is not such a file.
    nonisolated static func unfinishedLayout(of url: URL) -> WAVLayoutCore.Layout? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: WAVLayoutCore.maximumHeaderBytes),
              let fileSize = try? handle.seekToEnd(),
              case let .success(layout) = WAVLayoutCore.layout(header: [UInt8](header), fileSize: Int(fileSize)),
              layout.needsRepair
        else { return nil }
        return layout
    }

    /// Writes the two size fields `layout` asks for and checks that the file
    /// then reads as the audio found on disk. On any failure the original
    /// bytes are put back and false is returned. The file keeps `modified`
    /// as its date either way, so a later launch still dates it correctly.
    nonisolated static func repairHeader(of url: URL, _ layout: WAVLayoutCore.Layout, modified: Date) -> Bool {
        // The file must still be what the scan saw.
        guard unfinishedLayout(of: url) == layout, let handle = try? FileHandle(forUpdating: url) else { return false }
        defer {
            try? handle.close()
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        func write(_ bytes: Data, at offset: Int) throws {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: bytes)
        }
        let fields = [
            (offset: WAVLayoutCore.riffSizeFieldOffset, value: layout.repairedRIFFSize),
            (offset: layout.dataSizeFieldOffset, value: layout.repairedDataSize),
        ]
        var originals: [(offset: Int, bytes: Data)] = []
        var isRepaired = false
        do {
            for field in fields {
                try handle.seek(toOffset: UInt64(field.offset))
                guard let bytes = try handle.read(upToCount: 4), bytes.count == 4 else { return false }
                originals.append((field.offset, bytes))
            }
            for field in fields {
                try write(withUnsafeBytes(of: field.value.littleEndian) { Data($0) }, at: field.offset)
            }
            try handle.synchronize()
            // Regenerate hands this file to the engine, which reads it this way.
            if let seconds = audioDuration(of: url) {
                isRepaired = abs(seconds - layout.duration) <= 1 / Double(layout.sampleRate)
            }
        } catch {
            isRepaired = false
        }
        if !isRepaired {
            for original in originals { try? write(original.bytes, at: original.offset) }
            try? handle.synchronize()
        }
        return isRepaired
    }

    /// Seconds of audio the file's header describes; nil when the file does
    /// not open as audio.
    nonisolated static func audioDuration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    /// Whether another WorkFlow process is running right now.
    static func isAnotherWorkFlowRunning() -> Bool {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let identifiers = Set(
            [AppIdentity.bundleIdentifier] + AppIdentity.legacyBundleIdentifiers + [ownBundleIdentifier].compactMap { $0 }
        )
        return identifiers.contains { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { application in
                !application.isTerminated && isAnotherWorkFlow(
                    bundleIdentifier: application.bundleIdentifier,
                    processIdentifier: application.processIdentifier,
                    ownBundleIdentifier: ownBundleIdentifier,
                    ownProcessIdentifier: ownProcessIdentifier
                )
            }
        }
    }

    /// Whether a running application is another WorkFlow that shares the
    /// temporary recordings folder: any process but this one whose bundle
    /// identifier is this build's, WorkFlow's, or an earlier identity's.
    nonisolated static func isAnotherWorkFlow(
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        ownBundleIdentifier: String?,
        ownProcessIdentifier: pid_t
    ) -> Bool {
        guard processIdentifier != ownProcessIdentifier, let bundleIdentifier else { return false }
        return bundleIdentifier == ownBundleIdentifier
            || bundleIdentifier == AppIdentity.bundleIdentifier
            || AppIdentity.legacyBundleIdentifiers.contains(bundleIdentifier)
    }
}
