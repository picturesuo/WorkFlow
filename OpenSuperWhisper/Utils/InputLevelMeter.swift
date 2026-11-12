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

    /// Takes one reading: rises fast, falls slower. A reading that changes
    /// nothing is not published: every published value redraws whatever
    /// watches the meter, changed or not, so a silent microphone would
    /// otherwise redraw the record control 20 times a second.
    func push(_ sample: CGFloat) {
        let target = min(max(sample.isFinite ? sample : 0, 0), 1)
        var next = level + (target - level) * (target > level ? 0.65 : 0.3)
        if next < 0.005 { next = 0 }
        if next != level { level = next }
        var recent = history
        recent.removeFirst()
        recent.append(next)
        if recent != history { history = recent }
    }

    /// Back to silence when no recording is open.
    func reset() {
        guard level != 0 || history.contains(where: { $0 != 0 }) else { return }
        level = 0
        history = Array(repeating: 0, count: Self.historyLength)
    }
}

/// The meter's level for one view, which can be switched off. A view that
/// watches the meter itself is redrawn at the meter's rate whether or not
/// anyone can see it; a view that watches its feed is redrawn only while the
/// feed is on.
@MainActor
final class InputLevelFeed: ObservableObject {
    /// The meter's level while the feed is on, 0 while it is off.
    @Published private(set) var level: CGFloat = 0

    private let meter: InputLevelMeter
    private var subscription: AnyCancellable?

    /// Nil follows the app's shared meter.
    init(meter: InputLevelMeter? = nil) {
        self.meter = meter ?? .shared
    }

    /// Whether the feed follows the meter. Turning it on takes the meter's
    /// current level at once; turning it off returns the level to 0.
    var isOn: Bool {
        get { subscription != nil }
        set {
            guard newValue != isOn else { return }
            if newValue {
                // The meter publishes on the main actor, where it is pushed.
                subscription = meter.$level.sink { [weak self] level in
                    MainActor.assumeIsolated { self?.take(level) }
                }
            } else {
                subscription = nil
                take(0)
            }
        }
    }

    private func take(_ value: CGFloat) {
        if level != value { level = value }
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
