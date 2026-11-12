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
/// channels without a layout into silence. A file with one channel has no
/// plan and is read exactly as before. A file with more is measured once,
/// `ChannelMixCore` decides which channels carry the sound, and `convert`
/// mixes each chunk it reads to one channel before resampling it, so the mix
/// is never held or written at the source's rate.
enum SpeechAudioReader {
    /// Buffers hold Float32 per channel, so a chunk is capped by bytes.
    private static let maximumChunkBytes = 4 * 1024 * 1024

    /// What the recognizers take: 16 kHz, one channel, Float32.
    static let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Which channels of `url` the recognizer hears, or nil when it has one
    /// channel or no audio and is read as it is.
    static func channelPlan(for url: URL) throws -> ChannelMixCore.Plan? {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.channelCount > 1, file.length > 0 else { return nil }
        return ChannelMixCore.plan(try measure(file))
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

    /// Converts `frameCount` frames of the file from `startFrame` to
    /// `targetFormat`, one chunk at a time, and hands over each converted
    /// buffer. With a plan, every chunk is mixed to one channel first.
    static func convert(
        fileURL: URL,
        sourceFormat: AVAudioFormat,
        plan: ChannelMixCore.Plan?,
        targetFormat: AVAudioFormat,
        ratio: Double,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFramePosition,
        inputChunkSize: AVAudioFrameCount,
        output: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        let audioFile = try AVAudioFile(forReading: fileURL)
        audioFile.framePosition = startFrame

        // Buffers hold Float32 per channel, so cap the chunk by bytes: a chunk sized
        // in frames alone balloons for multi-channel sources (8ch = 32 MB per buffer).
        let maxChunkBytes = 8 * 1024 * 1024
        let bytesPerFrame = Int(sourceFormat.channelCount) * MemoryLayout<Float>.size
        let chunkFrames = min(inputChunkSize, AVAudioFrameCount(max(maxChunkBytes / bytesPerFrame, 65536)))

        var mixBuffer: AVAudioPCMBuffer?
        if plan != nil {
            guard let mixFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceFormat.sampleRate, channels: 1, interleaved: false
            ), let buffer = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: chunkFrames) else {
                throw TranscriptionError.audioConversionFailed
            }
            mixBuffer = buffer
        }

        guard let converter = AVAudioConverter(from: mixBuffer?.format ?? sourceFormat, to: targetFormat) else {
            throw TranscriptionError.audioConversionFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let outputChunkSize = AVAudioFrameCount(Double(chunkFrames) * ratio) + 256
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputChunkSize) else {
            throw TranscriptionError.audioConversionFailed
        }

        var framesRead: AVAudioFramePosition = 0

        while framesRead < frameCount {
            let framesToRead = min(AVAudioFrameCount(frameCount - framesRead), chunkFrames)
            inputBuffer.frameLength = 0
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)

            if inputBuffer.frameLength == 0 { break }
            framesRead += AVAudioFramePosition(inputBuffer.frameLength)

            let chunk: AVAudioPCMBuffer
            if let plan, let mixBuffer {
                try mix(inputBuffer, plan: plan, into: mixBuffer)
                chunk = mixBuffer
            } else {
                chunk = inputBuffer
            }

            var inputConsumed = false
            var convError: NSError?

            outputBuffer.frameLength = 0
            converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return chunk
            }

            if let convError = convError {
                throw convError
            }

            try output(outputBuffer)
        }

        // Flush the resampler: without an .endOfStream pass its internal latency
        // (the last few milliseconds of audio) is silently dropped.
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData {
            var convError: NSError?
            outputBuffer.frameLength = 0
            status = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if convError != nil { break }
            try output(outputBuffer)
        }
    }

    /// The planned channels of `source` as one channel in `mono`.
    private static func mix(_ source: AVAudioPCMBuffer, plan: ChannelMixCore.Plan, into mono: AVAudioPCMBuffer) throws {
        let picked = plan.channels
        guard let channels = source.floatChannelData, let samples = mono.floatChannelData?[0],
              source.frameLength <= mono.frameCapacity,
              picked.allSatisfy({ $0 < Int(source.format.channelCount) }) else {
            throw TranscriptionError.audioConversionFailed
        }
        let length = vDSP_Length(source.frameLength)
        vDSP_vclr(samples, 1, length)
        for channel in picked {
            vDSP_vadd(samples, 1, channels[channel], 1, samples, 1, length)
        }
        if picked.count > 1 {
            var scale = 1 / Float(picked.count)
            vDSP_vsmul(samples, 1, &scale, samples, 1, length)
        }
        mono.frameLength = source.frameLength
    }

    /// The whole of a recording with several channels as 16 kHz samples of
    /// its mix.
    static func speechSamples(of url: URL, plan: ChannelMixCore.Plan) throws -> [Float] {
        var samples = [Float]()
        try convertToSpeech(url, plan: plan) { buffer in
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { return }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        return samples
    }

    /// Writes the mix of a recording with several channels to `destination`
    /// as a 16 kHz, 16-bit, one-channel WAV: the one file FluidAudio's
    /// long-form path reads in place instead of converting it to a temporary
    /// file of its own.
    static func writeSpeechFile(of url: URL, plan: ChannelMixCore.Plan, to destination: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: speechFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        let file = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try convertToSpeech(url, plan: plan) { buffer in
            guard buffer.frameLength > 0 else { return }
            try file.write(from: buffer)
        }
    }

    private static func convertToSpeech(_ url: URL, plan: ChannelMixCore.Plan, output: (AVAudioPCMBuffer) throws -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        try convert(
            fileURL: url,
            sourceFormat: sourceFormat,
            plan: plan,
            targetFormat: speechFormat,
            ratio: speechFormat.sampleRate / sourceFormat.sampleRate,
            startFrame: 0,
            frameCount: file.length,
            inputChunkSize: 262_144,
            output: output
        )
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
