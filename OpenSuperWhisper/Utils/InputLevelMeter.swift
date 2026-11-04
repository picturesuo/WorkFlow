import Combine
import CoreGraphics
import Foundation

/// How loud the open recording is, so the record control and the floating
/// indicator move only when the microphone actually hears something. Nothing
/// here is stored: the level exists only while a recording is open.
@MainActor
final class InputLevelMeter: ObservableObject {
    static let shared = InputLevelMeter()
    /// Bars the indicator's waveform draws.
    static let historyLength = 9

    /// 0 for silence or no recording, 1 for loud speech; smoothed like a VU meter.
    @Published private(set) var level: CGFloat = 0
    /// Recent levels, oldest first.
    @Published private(set) var history: [CGFloat] = Array(repeating: 0, count: historyLength)

    init() {}

    /// Average power in dBFS mapped to 0...1. Quiet rooms sit near -55 dB,
    /// normal speech near -25 dB, and anything from -10 dB up is full scale.
    nonisolated static func normalized(decibels: Float) -> CGFloat {
        guard decibels.isFinite else { return 0 }
        return CGFloat(min(max((decibels + 55) / 45, 0), 1))
    }

    /// The root mean square of the first channel of float samples, in dBFS.
    nonisolated static func decibels(samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return -160 }
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }

    /// Takes one reading: rises fast, falls slower.
    func push(_ sample: CGFloat) {
        let target = min(max(sample.isFinite ? sample : 0, 0), 1)
        level += (target - level) * (target > level ? 0.65 : 0.3)
        if level < 0.005 { level = 0 }
        history.removeFirst()
        history.append(level)
    }

    /// Back to silence when no recording is open.
    func reset() {
        guard level != 0 || history.contains(where: { $0 != 0 }) else { return }
        level = 0
        history = Array(repeating: 0, count: Self.historyLength)
    }
}

/// Thread-safe latest reading from an audio tap.
final class InputLevelProbe {
    private let lock = NSLock()
    private var value: CGFloat = 0

    var level: CGFloat {
        lock.withLock { value }
    }

    func record(decibels: Float) {
        let level = InputLevelMeter.normalized(decibels: decibels)
        lock.withLock { value = level }
    }
}
