import DictationCore
import XCTest

/// One test per row of `ChannelMixCore`'s table, on measurements computed
/// from small synthetic channels, plus a property test over random
/// recordings: the planned mix is never silent while a channel carries
/// sound.
final class ChannelMixCoreTests: XCTestCase {
    typealias Plan = ChannelMixCore.Plan

    /// What a caller measures: each channel's energy and the energy of the
    /// per-frame sum across channels.
    private func measure(_ channels: [[Double]]) -> ChannelMixCore.Measurement {
        let frames = channels.first?.count ?? 0
        var sumEnergy = 0.0
        for frame in 0..<frames {
            let sum = channels.reduce(0) { $0 + $1[frame] }
            sumEnergy += sum * sum
        }
        return ChannelMixCore.Measurement(
            channelEnergy: channels.map { $0.reduce(0) { $0 + $1 * $1 } },
            sumEnergy: sumEnergy,
            frames: frames
        )
    }

    private func tone(_ amplitude: Double, frequency: Double = 220, frames: Int = 1_600) -> [Double] {
        (0..<frames).map { amplitude * sin(2 * .pi * frequency * Double($0) / 16_000) }
    }

    private func silence(frames: Int = 1_600) -> [Double] {
        [Double](repeating: 0, count: frames)
    }

    /// The mean square of the planned mix.
    private func mixedMeanSquare(_ channels: [[Double]], _ plan: Plan) -> Double {
        let frames = channels.first?.count ?? 0
        guard frames > 0 else { return 0 }
        let picked = plan.channels
        var energy = 0.0
        for frame in 0..<frames {
            let value = picked.reduce(0) { $0 + channels[$1][frame] } / Double(picked.count)
            energy += value * value
        }
        return energy / Double(frames)
    }

    // MARK: - Table rows

    func testEveryChannelSilentAveragesEveryChannel() {
        XCTAssertEqual(ChannelMixCore.plan(measure([silence(), silence(), silence()])), .average([0, 1, 2]))
        // Below the floor counts as silence too.
        XCTAssertEqual(ChannelMixCore.plan(measure([tone(0.00005), silence()])), .average([0, 1]))
    }

    func testOneChannelWithSoundIsTakenAtItsOwnLevel() {
        for channel in 0..<4 {
            var channels = [[Double]](repeating: silence(), count: 4)
            channels[channel] = tone(0.3)
            XCTAssertEqual(ChannelMixCore.plan(measure(channels)), .single(channel), "Voice on input \(channel + 1) of 4")
        }
        // The second input of a two-input interface: Core Audio's own
        // conversion to one channel dropped it.
        XCTAssertEqual(ChannelMixCore.plan(measure([silence(), tone(0.3)])), .single(1))
    }

    func testSeveralChannelsWithSoundAreAveraged() {
        // The same voice on both channels of a stereo file.
        XCTAssertEqual(ChannelMixCore.plan(measure([tone(0.3), tone(0.3)])), .average([0, 1]))
        // A microphone and unrelated system audio on an aggregate device.
        XCTAssertEqual(
            ChannelMixCore.plan(measure([tone(0.3), tone(0.1, frequency: 347), tone(0.1, frequency: 513)])),
            .average([0, 1, 2])
        )
    }

    func testIdleInputsFarBelowTheVoiceAreLeftOutOfTheAverage() {
        // An eight-input interface: one microphone, seven inputs of hiss
        // more than 40 dB below it.
        var channels = (0..<8).map { tone(0.0005, frequency: 100 + Double($0) * 37) }
        channels[2] = tone(0.3)
        XCTAssertEqual(ChannelMixCore.plan(measure(channels)), .single(2), "The voice keeps its level instead of an eighth of it")

        // A quieter source within 40 dB still counts: people on a call,
        // 25 dB under the local microphone.
        XCTAssertEqual(
            ChannelMixCore.plan(measure([tone(0.3), tone(0.017, frequency: 347)])),
            .average([0, 1])
        )
    }

    func testChannelsThatCancelUseTheLoudestOneAlone() {
        let voice = tone(0.3)
        // The same signal with opposite polarity sums to nothing.
        XCTAssertEqual(ChannelMixCore.plan(measure([voice, voice.map { -$0 }])), .single(0))
        // The first of equally loud channels, whichever order they come in.
        XCTAssertEqual(ChannelMixCore.plan(measure([voice.map { -$0 }, voice])), .single(0))
        // A quieter unrelated third channel does not rescue the sum.
        XCTAssertEqual(
            ChannelMixCore.plan(measure([voice, voice.map { -$0 }, tone(0.05, frequency: 347)])),
            .single(0)
        )
    }

    func testOneChannelAndEmptyInputsNeverTrap() {
        XCTAssertEqual(ChannelMixCore.plan(.init(channelEnergy: [1], sumEnergy: 1, frames: 10)), .single(0))
        XCTAssertEqual(ChannelMixCore.plan(.init(channelEnergy: [], sumEnergy: 0, frames: 0)), .single(0))
        XCTAssertEqual(ChannelMixCore.plan(.init(channelEnergy: [1, 1], sumEnergy: 4, frames: 0)), .average([0, 1]))
        XCTAssertEqual(
            ChannelMixCore.plan(.init(channelEnergy: [.nan, 1], sumEnergy: .infinity, frames: 10)),
            .single(1),
            "A value that is not a number counts as silence"
        )
    }

    // MARK: - Property

    func testThePlannedMixIsNeverSilentWhileAChannelCarriesSound() {
        var generator = SplitMix64(seed: 0x51C4)
        for _ in 0..<400 {
            let channelCount = Int.random(in: 2...16, using: &generator)
            let frames = 800
            // Each channel is silence, hiss, a voice, or another channel's
            // voice with either polarity.
            let voice = tone(Double.random(in: 0.01...0.6, using: &generator), frequency: Double.random(in: 90...400, using: &generator), frames: frames)
            let channels: [[Double]] = (0..<channelCount).map { _ in
                switch Int.random(in: 0...4, using: &generator) {
                case 0: return silence(frames: frames)
                case 1: return tone(Double.random(in: 0.00001...0.001, using: &generator), frequency: Double.random(in: 50...3_000, using: &generator), frames: frames)
                case 2: return voice
                case 3: return voice.map { -$0 }
                default: return tone(Double.random(in: 0.01...0.6, using: &generator), frequency: Double.random(in: 90...3_000, using: &generator), frames: frames)
                }
            }
            let measurement = measure(channels)
            let plan = ChannelMixCore.plan(measurement)
            let loudest = (measurement.channelEnergy.max() ?? 0) / Double(frames)

            XCTAssertFalse(plan.channels.isEmpty)
            XCTAssertEqual(plan.channels, plan.channels.sorted(), "Channels are read in order")
            XCTAssertEqual(Set(plan.channels).count, plan.channels.count)
            XCTAssertTrue(plan.channels.allSatisfy { $0 >= 0 && $0 < channelCount })
            XCTAssertEqual(plan, ChannelMixCore.plan(measurement), "The plan is a function of the measurement")

            guard loudest > ChannelMixCore.silenceFloor else { continue }
            // Averaging n channels can lower a lone voice by n at most; the
            // plan never lets cancellation take it lower than that.
            let counted = Double(plan.channels.count)
            let floor = loudest * ChannelMixCore.minimumSumShare / (counted * counted) * 0.99
            XCTAssertGreaterThanOrEqual(
                mixedMeanSquare(channels, plan), floor,
                "\(channelCount) channels, plan \(plan): the mix lost the sound"
            )
        }
    }
}
