import Foundation

/// Recognizes a recording piece by piece as its audio arrives, so only the
/// last piece is left when the recording stops.
///
/// Fed a whole file at once, it makes the same pieces and the same calls to
/// the recognizer, so live recognition and recognizing the finished file agree
/// word for word.
final class SegmentedTranscriber {
    /// Recognizes one piece, at most `SpeechSegmenter.holdSamples` long.
    typealias Recognize = (_ samples: [Float], _ startSeconds: Double) async throws -> String

    private let recognize: Recognize
    private var segmenter: SpeechSegmenter
    private var texts: [String] = []
    /// Pieces recognized so far, silent ones included.
    private(set) var recognizedPieces = 0
    /// The audio of the current piece, from its start to the newest sample.
    private var samples: [Float] = []
    /// Where `samples` begins in the recording.
    private var samplesStart = 0

    init(segmenter: SpeechSegmenter = SpeechSegmenter(), recognize: @escaping Recognize) {
        self.segmenter = segmenter
        self.recognize = recognize
    }

    /// Adds samples and recognizes every piece they complete.
    func append<C: Collection>(_ newSamples: C) async throws where C.Element == Float {
        samples.append(contentsOf: newSamples)
        for piece in segmenter.append(newSamples) {
            try await recognizePiece(piece)
        }
        if segmenter.pieceStart > samplesStart {
            samples.removeFirst(segmenter.pieceStart - samplesStart)
            samplesStart = segmenter.pieceStart
        }
    }

    /// Recognizes the rest and returns the whole transcript.
    func finish() async throws -> String {
        if let piece = segmenter.finish() {
            try await recognizePiece(piece)
        }
        return Self.join(texts)
    }

    /// The transcript of consecutive pieces: each piece's text, in order,
    /// one space apart, with silent pieces adding nothing.
    static func join<S: Sequence>(_ pieceTexts: S) -> String where S.Element == String {
        pieceTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func recognizePiece(_ piece: Range<Int>) async throws {
        try Task.checkCancellation()
        let local = (piece.lowerBound - samplesStart)..<(piece.upperBound - samplesStart)
        texts.append(try await recognize(
            Array(samples[local]),
            Double(piece.lowerBound) / Double(SpeechSegmenter.sampleRate)
        ))
        recognizedPieces += 1
    }
}
