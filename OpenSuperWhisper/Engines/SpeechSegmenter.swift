import Foundation

/// Splits 16 kHz mono audio into pieces that Parakeet recognizes one 15 s
/// window at a time, cutting in the quietest stretch of speech.
///
/// Every piece begins at a cut, in a pause, because Parakeet can skip the
/// opening words of a window that begins mid-speech, and the pieces do not
/// overlap, so a piece's text is simply joined to the one before it.
///
/// A cut depends only on the audio up to `holdSamples` past the start of its
/// piece, so cutting while the recording grows and cutting the finished file
/// give exactly the same pieces. That is what lets a dictation be recognized
/// while it is still being recorded without changing a word of the result.
struct SpeechSegmenter {
    static let sampleRate = 16_000
    /// Loudness is compared over 20 ms frames.
    static let frameSamples = 320
    /// The quietest stretch is judged over 200 ms, so a cut lands in a pause
    /// between words rather than in a dip inside one.
    static let quietWindowFrames = 10

    /// A cut never makes a piece shorter than this, so every piece keeps
    /// enough context for the recognizer.
    let minimumSamples: Int
    /// A cut is chosen at or before this point in the piece.
    let maximumSamples: Int
    /// A piece is held until the audio reaches this far past its start: the
    /// last piece of a recording may run this long without a cut, so a
    /// recording up to this long is one piece, a single window as before.
    let holdSamples: Int

    /// Where the current, unfinished piece starts.
    private(set) var pieceStart = 0
    /// All audio seen so far.
    private(set) var receivedSamples = 0
    /// Mean square loudness of every complete 20 ms frame since the start.
    private var frameEnergy: [Float] = []
    private var partialFrame: [Float] = []

    init(minimumSeconds: Double = 6, maximumSeconds: Double = 14, holdSeconds: Double = 14.9) {
        minimumSamples = Int(minimumSeconds * Double(Self.sampleRate))
        maximumSamples = Int(maximumSeconds * Double(Self.sampleRate))
        holdSamples = Int(holdSeconds * Double(Self.sampleRate))
        precondition(minimumSamples + Self.quietWindowFrames * Self.frameSamples < maximumSamples)
        precondition(maximumSamples <= holdSamples)
    }

    /// Adds the next samples and returns every piece that is now final.
    mutating func append<C: Collection>(_ samples: C) -> [Range<Int>] where C.Element == Float {
        for sample in samples {
            partialFrame.append(sample)
            if partialFrame.count == Self.frameSamples {
                frameEnergy.append(Self.meanSquare(partialFrame))
                partialFrame.removeAll(keepingCapacity: true)
            }
        }
        receivedSamples += samples.count
        var pieces: [Range<Int>] = []
        while receivedSamples - pieceStart >= holdSamples {
            let cut = chooseCut()
            pieces.append(pieceStart..<cut)
            pieceStart = cut
        }
        return pieces
    }

    /// Ends the audio and returns its last piece. `append` already cut
    /// everything longer than `holdSamples`, so the rest fits one window.
    mutating func finish() -> Range<Int>? {
        guard receivedSamples > pieceStart else { return nil }
        defer { pieceStart = receivedSamples }
        return pieceStart..<receivedSamples
    }

    /// The middle of the quietest 200 ms between the minimum and maximum
    /// length; on a tie, the later one, so pieces stay long.
    private func chooseCut() -> Int {
        let window = Self.quietWindowFrames
        let firstFrame = (pieceStart + minimumSamples + Self.frameSamples - 1) / Self.frameSamples
        let lastFrame = (pieceStart + maximumSamples) / Self.frameSamples - window
        guard lastFrame >= firstFrame, lastFrame + window <= frameEnergy.count else {
            return pieceStart + maximumSamples
        }
        var running: Float = 0
        for frame in firstFrame..<(firstFrame + window) {
            running += frameEnergy[frame]
        }
        var bestFrame = firstFrame
        var bestEnergy = running
        if firstFrame < lastFrame {
            for frame in (firstFrame + 1)...lastFrame {
                running += frameEnergy[frame + window - 1] - frameEnergy[frame - 1]
                if running <= bestEnergy {
                    bestEnergy = running
                    bestFrame = frame
                }
            }
        }
        return (bestFrame + window / 2) * Self.frameSamples
    }

    private static func meanSquare(_ frame: [Float]) -> Float {
        var sum: Float = 0
        for sample in frame {
            sum += sample * sample
        }
        return sum / Float(frame.count)
    }
}
