import Foundation

/// Decides which channels of a recording with more than one channel the
/// recognizer hears.
///
/// A recognizer takes one channel. Core Audio's own conversion to one channel
/// keeps only the first channel of a stereo file (the center of a surround
/// file) and turns a file whose three or more channels carry no layout into
/// silence, so a voice on any other input was lost: a microphone on the
/// second input of an audio interface, or any device with three or more
/// inputs, was recognized as no speech at all.
///
/// `plan` decides once for the whole recording, from how loud each channel
/// is over all of it, so the level never steps in the middle of a sentence.
/// It decides only; the caller measures the file and mixes it.
///
/// | Channels that carry sound | Plan |
/// |---|---|
/// | none (every channel is below `silenceFloor`) | the average of every channel |
/// | one | that channel, at its own level |
/// | several, and summing them keeps their energy | their average |
/// | several, and summing them cancels most of it | the loudest one alone |
///
/// A channel carries sound when its mean square is above `silenceFloor` and
/// within `quietestCountedRatio` of the loudest channel. A voice on one input
/// of an interface with many idle inputs therefore keeps its level instead
/// of being divided by the number of inputs.
///
/// Summing cancels when two channels hold the same signal with opposite
/// polarity, which a miswired balanced cable or a mid/side file does. The
/// energy of the sum is then far below the energy of the channels, and the
/// average would be near silence, so the loudest channel is taken alone.
public enum ChannelMixCore {
    /// A mean square below this is silence: an RMS of 0.0001, 80 dB under
    /// full scale.
    public static let silenceFloor: Double = 1e-8
    /// A channel this far under the loudest one (40 dB) is left out of the
    /// average.
    public static let quietestCountedRatio: Double = 1e-4
    /// The sum of the counted channels must keep at least this share of
    /// their combined energy, or the loudest channel is taken alone.
    public static let minimumSumShare: Double = 0.5

    /// What the caller measured over the whole recording.
    public struct Measurement: Sendable, Hashable {
        /// The sum of squares of each channel's samples.
        public var channelEnergy: [Double]
        /// The sum of squares of every frame's sum across all channels.
        public var sumEnergy: Double
        /// How many frames were measured.
        public var frames: Int

        public init(channelEnergy: [Double], sumEnergy: Double, frames: Int) {
            self.channelEnergy = channelEnergy
            self.sumEnergy = sumEnergy
            self.frames = frames
        }
    }

    public enum Plan: Sendable, Hashable {
        /// The average of these channels, in order.
        case average([Int])
        /// One channel at its own level.
        case single(Int)

        /// The channels the mix reads.
        public var channels: [Int] {
            switch self {
            case let .average(channels): channels
            case let .single(channel): [channel]
            }
        }
    }

    public static func plan(_ measurement: Measurement) -> Plan {
        let energies = measurement.channelEnergy.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let everyChannel = Array(energies.indices)
        guard energies.count > 1 else { return .single(0) }
        guard measurement.frames > 0 else { return .average(everyChannel) }

        let frames = Double(measurement.frames)
        // The first of equally loud channels, so the plan never depends on
        // how ties are broken.
        guard let loudest = everyChannel.max(by: { energies[$0] < energies[$1] || (energies[$0] == energies[$1] && $0 > $1) }),
              energies[loudest] / frames > silenceFloor
        else { return .average(everyChannel) }

        let counted = everyChannel.filter {
            energies[$0] / frames > silenceFloor && energies[$0] >= energies[loudest] * quietestCountedRatio
        }
        guard counted.count > 1 else { return .single(loudest) }

        let countedEnergy = counted.reduce(0) { $0 + energies[$1] }
        let sumEnergy = measurement.sumEnergy.isFinite ? max(measurement.sumEnergy, 0) : 0
        guard sumEnergy >= countedEnergy * minimumSumShare else { return .single(loudest) }
        return .average(counted)
    }
}
