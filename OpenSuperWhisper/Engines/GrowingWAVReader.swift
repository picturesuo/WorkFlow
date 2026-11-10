import Foundation

/// Reads the 16-bit mono 16 kHz PCM samples of a WAV file while the recorder
/// is still writing it.
///
/// The recorder fills in the header's sizes only when it stops, so they are
/// never trusted: the reader takes the format from the `fmt ` chunk, finds
/// where the `data` chunk's samples begin, and returns only whole samples that
/// are already on disk. Each sample is `Int16 / 32768`, the value
/// `AVAudioFile` gives for the same file once it is finished.
final class GrowingWAVReader {
    enum ReadError: Error, Equatable {
        /// The file is not 16-bit mono 16 kHz PCM, so it is left to the
        /// finished-file path.
        case unsupportedFormat
        case malformedHeader
    }

    static let sampleRate = 16_000
    /// The recorder pads its header to 4 KB; real headers stay well inside this.
    static let maximumHeaderBytes = 65_536

    private let url: URL
    private var handle: FileHandle?
    private var dataOffset: UInt64?
    private var pendingByte: UInt8?
    /// Samples returned so far.
    private(set) var samplesRead = 0

    init(url: URL) {
        self.url = url
    }

    deinit {
        try? handle?.close()
    }

    /// Returns the samples written since the last call; empty while the
    /// header is not on disk yet.
    func readAvailable() throws -> [Float] {
        if dataOffset == nil {
            guard let offset = try Self.locateSamples(in: url) else { return [] }
            dataOffset = offset
            handle = try FileHandle(forReadingFrom: url)
            try handle?.seek(toOffset: offset)
        }
        guard let handle else { return [] }
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty || pendingByte != nil else { return [] }
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count + 1)
        if let pendingByte { bytes.append(pendingByte) }
        bytes.append(contentsOf: data)
        let whole = bytes.count / 2 * 2
        pendingByte = whole < bytes.count ? bytes[whole] : nil
        var samples = [Float]()
        samples.reserveCapacity(whole / 2)
        var index = 0
        while index < whole {
            let value = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            samples.append(Float(value) / 32_768)
            index += 2
        }
        samplesRead += samples.count
        return samples
    }

    /// Where the samples begin, or nil while the header is incomplete.
    static func locateSamples(in url: URL) throws -> UInt64? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: maximumHeaderBytes) ?? Data()
        return try locateSamples(inHeader: [UInt8](header))
    }

    static func locateSamples(inHeader bytes: [UInt8]) throws -> UInt64? {
        func ascii(_ offset: Int) -> String {
            String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
        }
        func uint32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        func uint16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        guard bytes.count >= 12 else { return nil }
        guard ascii(0) == "RIFF", ascii(8) == "WAVE" else { throw ReadError.malformedHeader }
        var offset = 12
        var sawFormat = false
        while offset + 8 <= bytes.count {
            let id = ascii(offset)
            let size = Int(uint32(offset + 4))
            let body = offset + 8
            if id == "data" {
                guard sawFormat else { throw ReadError.malformedHeader }
                return UInt64(body)
            }
            if id == "fmt " {
                guard size >= 16, body + 16 <= bytes.count else { return nil }
                var formatTag = uint16(body)
                let channels = uint16(body + 2)
                let sampleRate = uint32(body + 4)
                let bitsPerSample = uint16(body + 14)
                // WAVE_FORMAT_EXTENSIBLE names its real format in a sub-GUID.
                if formatTag == 0xFFFE {
                    guard size >= 40, body + 26 <= bytes.count else { return nil }
                    formatTag = uint16(body + 24)
                }
                guard formatTag == 1, channels == 1, sampleRate == UInt32(Self.sampleRate), bitsPerSample == 16 else {
                    throw ReadError.unsupportedFormat
                }
                sawFormat = true
            }
            guard size < maximumHeaderBytes else { throw ReadError.malformedHeader }
            offset = body + size + (size % 2)
        }
        if offset >= maximumHeaderBytes { throw ReadError.malformedHeader }
        return nil
    }
}
