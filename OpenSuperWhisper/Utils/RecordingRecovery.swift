import AppKit
import AVFoundation
import DictationCore
import Foundation

/// Runs `RecordingRecoveryCore` at launch: recordings a WorkFlow left in the
/// temporary folder when it quit, crashed or was force-quit before they
/// reached History become failed History rows that keep their audio and
/// offer Regenerate. Nothing is transcribed, pasted or copied here, and no
/// file is ever deleted here.
@MainActor
enum RecordingRecovery {
    /// Why a recovered row has no transcript. Its description is the row's
    /// History text, shown the way every failed row's message is.
    struct ClosedBeforeTranscription: LocalizedError {
        var errorDescription: String? {
            "Recovered recording - \(AppIdentity.productName) closed before this was transcribed. Select Regenerate to transcribe it."
        }
    }

    /// Adopts the orphaned recordings in `directory` and returns how many
    /// History rows were added.
    @discardableResult
    static func adoptOrphans(
        in directory: URL,
        launchedAt: Date,
        store: RecordingStore,
        cleanupPipeline: TranscriptCleanupPipeline,
        anotherWorkFlowIsRunning: () -> Bool,
        keepAudio: (URL, URL) -> URL?
    ) async -> Int {
        0
    }

    /// Whether a running application is another WorkFlow, of this or an
    /// earlier identity, that shares the temporary recordings folder.
    nonisolated static func isAnotherWorkFlow(
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        ownBundleIdentifier: String?,
        ownProcessIdentifier: pid_t
    ) -> Bool {
        false
    }
}
