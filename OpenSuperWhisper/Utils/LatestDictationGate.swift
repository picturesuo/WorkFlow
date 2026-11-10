@MainActor
final class LatestDictationGate {
    static let shared = LatestDictationGate()

    private var latestGeneration: UInt64 = 0
    private var claimedGeneration: UInt64?

    func begin() -> UInt64 {
        latestGeneration &+= 1
        claimedGeneration = nil
        return latestGeneration
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == latestGeneration
    }

    /// Atomically grants paste ownership to the newest dictation exactly once.
    func claimIfCurrent(_ generation: UInt64) -> Bool {
        guard generation == latestGeneration, claimedGeneration != generation else {
            return false
        }
        claimedGeneration = generation
        return true
    }
}
