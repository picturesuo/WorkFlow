import Foundation

/// Serializes tests that write to or watch `NSPasteboard.general` across the
/// worker processes Xcode uses for parallel testing. The general pasteboard is
/// one machine-wide object, so a `changeCount` observed in one process moves
/// when a test in another process pastes. A file lock in the per-user
/// temporary directory is visible to every worker, unlike any in-process lock.
final class GeneralPasteboardLock {
    private static let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("workflow-tests-general-pasteboard.lock").path

    private var descriptor: Int32 = -1

    /// Blocks until no other test process holds the general pasteboard.
    func lock() {
        descriptor = open(Self.path, O_CREAT | O_RDWR, 0o644)
        precondition(descriptor >= 0, "Cannot open the general pasteboard lock file")
        precondition(flock(descriptor, LOCK_EX) == 0, "Cannot lock the general pasteboard")
    }

    func unlock() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
