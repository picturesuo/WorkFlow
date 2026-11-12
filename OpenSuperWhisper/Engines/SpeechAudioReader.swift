import Accelerate
import AVFoundation
import DictationCore
import Foundation

/// Gives the recognizers one channel of a recording that has several.
///
/// The recorder writes every input channel of the microphone, and an imported
/// file can be stereo or surround. A recognizer takes one channel, and Core
/// Audio's own conversion to one channel keeps only the first channel of a
/// stereo file (the center of a surround file) and turns three or more
/// channels without a layout into silence. A file with one channel is
/// returned as it is, so nothing changes for it. A file with more is measured
/// once, `ChannelMixCore` decides which channels carry the sound, and that mix
/// is written to a temporary one-channel file at the same sample rate, which
/// the engines then read exactly as they read any one-channel recording.
enum SpeechAudioReader {
    /// The file a recognizer reads.
    struct MonoSource {
        let url: URL
        /// Whether `url` is a temporary mix that `discard` removes.
        let isTemporary: Bool

        func discard() {
            guard isTemporary else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Buffers hold Float32 per channel, so a chunk is capped by bytes.
    private static let maximumChunkBytes = 4 * 1024 * 1024

    /// `url` itself when it has one channel or no audio; otherwise a
    /// temporary one-channel mix of it, which the caller discards after use.
    static func monoSource(for url: URL) throws -> MonoSource {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.channelCount > 1, file.length > 0 else {
            return MonoSource(url: url, isTemporary: false)
        }
        let plan = ChannelMixCore.plan(try measure(file))
        file.framePosition = 0
        let mixURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-channel-mix-\(UUID().uuidString).caf")
        do {
            try writeMix(of: file, plan: plan, to: mixURL)
        } catch {
            try? FileManager.default.removeItem(at: mixURL)
            throw error
        }
        return MonoSource(url: mixURL, isTemporary: true)
    }

    /// How loud each channel of the file is, and how loud their sum is.
    static func measure(_ url: URL) throws -> ChannelMixCore.Measurement {
        try measure(AVAudioFile(forReading: url))
    }

    private static func measure(_ file: AVAudioFile) throws -> ChannelMixCore.Measurement {
        let channelCount = Int(file.processingFormat.channelCount)
        var channelEnergy = [Double](repeating: 0, count: channelCount)
        var sumEnergy = 0.0
        var frames = 0
        var sum = [Float]()
        try forEachChunk(of: file) { channels, count in
            if sum.count < count { sum = [Float](repeating: 0, count: count) }
            let length = vDSP_Length(count)
            sum.withUnsafeMutableBufferPointer { sumPointer in
                guard let sumBase = sumPointer.baseAddress else { return }
                vDSP_vclr(sumBase, 1, length)
                for channel in 0..<channelCount {
                    var energy: Float = 0
                    vDSP_svesq(channels[channel], 1, &energy, length)
                    channelEnergy[channel] += Double(energy)
                    vDSP_vadd(sumBase, 1, channels[channel], 1, sumBase, 1, length)
                }
                var energy: Float = 0
                vDSP_svesq(sumBase, 1, &energy, length)
                sumEnergy += Double(energy)
            }
            frames += count
        }
        return ChannelMixCore.Measurement(channelEnergy: channelEnergy, sumEnergy: sumEnergy, frames: frames)
    }

    private static func writeMix(of file: AVAudioFile, plan: ChannelMixCore.Plan, to url: URL) throws {
        let sampleRate = file.processingFormat.sampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true
        ]
        let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let picked = plan.channels
        var scale = 1 / Float(max(picked.count, 1))
        var mix: AVAudioPCMBuffer?
        try forEachChunk(of: file) { channels, count in
            if mix == nil || Int(mix?.frameCapacity ?? 0) < count {
                mix = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(count))
            }
            guard let mix, let samples = mix.floatChannelData?[0] else {
                throw TranscriptionError.audioConversionFailed
            }
            let length = vDSP_Length(count)
            vDSP_vclr(samples, 1, length)
            for channel in picked {
                vDSP_vadd(samples, 1, channels[channel], 1, samples, 1, length)
            }
            if picked.count > 1 {
                vDSP_vsmul(samples, 1, &scale, samples, 1, length)
            }
            mix.frameLength = AVAudioFrameCount(count)
            try output.write(from: mix)
        }
    }

    /// Reads the file from its current position, one chunk at a time, and
    /// hands over each channel's samples.
    private static func forEachChunk(
        of file: AVAudioFile,
        _ body: (_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, _ frames: Int) throws -> Void
    ) throws {
        let format = file.processingFormat
        let bytesPerFrame = max(Int(format.channelCount), 1) * MemoryLayout<Float>.size
        let chunkFrames = max(4_096, min(Int(format.sampleRate), maximumChunkBytes / bytesPerFrame))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)) else {
            throw TranscriptionError.audioConversionFailed
        }
        var readAny = false
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let remaining = Int(file.length - file.framePosition)
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(chunkFrames, remaining)))
            } catch {
                // A compressed file's length is an estimate that can run a
                // little past what decodes; a failed read after real audio
                // is the end of the file.
                if readAny { return }
                throw error
            }
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { return }
            readAny = true
            try body(channels, count)
        }
    }
}
