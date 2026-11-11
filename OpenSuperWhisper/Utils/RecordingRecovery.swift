import AppKit
import AVFoundation
import DictationCore
import Foundation

/// Runs `RecordingRecoveryCore` at launch: recordings a WorkFlow left in the
/// temporary folder when it quit, crashed or was force-quit before they
/// reached History become failed History rows that keep their audio and
/// offer Regenerate. Nothing is transcribed, pasted or copied here, and no
/// file is ever deleted here: what is not adopted stays for the 24-hour sweep.
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
        let candidates = await Task.detached(priority: .utility) {
            scan(directory, referenced: referenced)
        }.value
        let orphans = RecordingRecoveryCore.filesToAdopt(
            candidates,
            launchedAt: launchedAt,
            minimumDuration: AudioRecorder.minimumRecordingDuration
        )
        guard !orphans.isEmpty else { return 0 }

        // Regenerate uses the filter selected now, as for a queued recording:
        // the one selected when it was recorded is not known.
        let plan = cleanupPipeline.selectedPlan()
        let cleanupRequested = cleanupPipeline.cleanupRequested(targetBundleID: nil)
        var adopted = 0
        for orphan in orphans {
            guard let modified = orphan.modified, let duration = orphan.duration else { continue }
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

    /// Reads the folder: every regular file with its date, its audio length,
    /// and whether History references it. Nothing is changed.
    nonisolated static func scan(_ directory: URL, referenced: Set<String>) -> [RecordingRecoveryCore.Candidate] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else { return [] }
        return files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return RecordingRecoveryCore.Candidate(
                url: file,
                modified: values.contentModificationDate,
                duration: audioDuration(of: file),
                isReferenced: referenced.contains(file.standardizedFileURL.path)
            )
        }
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
