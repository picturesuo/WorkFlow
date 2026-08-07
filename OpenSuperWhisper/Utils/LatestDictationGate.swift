@MainActor
final class LatestDictationGate {
    private var latestGeneration: UInt64 = 0

    func begin() -> UInt64 {
        latestGeneration &+= 1
        return latestGeneration
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == latestGeneration
    }
}
