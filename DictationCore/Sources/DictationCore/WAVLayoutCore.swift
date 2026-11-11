import Foundation

/// Reads the layout of a PCM WAV file from its first bytes and its size on
/// disk, without trusting the sizes its header declares.
///
/// A recorder fills in the RIFF size and the `data` chunk size only when it
/// stops. A process killed while recording therefore leaves every sample on
/// disk behind a header that declares none, and the file reads as empty.
/// `layout` says where the samples are, how many whole frames are on disk,
/// and which two size fields a repair must write so that any reader finds
/// them. It decides only; the caller does the reading and the writing.
///
/// Chunks are walked from byte 12: a four-byte id, a little-endian size, the
/// body, and one pad byte after an odd-sized body. CoreAudio writes a `JUNK`
/// chunk and a `FLLR` filler chunk around `fmt `, so `data` usually starts
/// at byte 4096.
///
/// | Declared `data` size | Payload taken as | Repair needed |
/// |---|---|---|
/// | 0, 0xFFFFFFFF, or more than is on disk | what is on disk after the chunk header | yes |
/// | anything else | the declared size | only when the RIFF size does not span the `data` chunk or runs past the file |
///
/// The payload is rounded down to a whole block align, so a frame cut in
/// half by the kill is not counted. Only integer PCM is accepted (format tag
/// 1, or `WAVE_FORMAT_EXTENSIBLE` naming it); every other file is rejected
/// and must not be touched.
public enum WAVLayoutCore {
    /// How much of a file's start `layout` needs at most.
    public static let maximumHeaderBytes = 65_536
    /// Where the RIFF chunk's size is written.
    public static let riffSizeFieldOffset = 4

    public struct Layout: Sendable, Hashable {
        /// Where the samples begin.
        public var dataOffset: Int
        /// Bytes of whole frames that are on disk.
        public var payloadByteCount: Int
        /// `payloadByteCount` over the byte rate.
        public var duration: TimeInterval
        /// Whether the size fields must be rewritten before a reader that
        /// trusts them sees this audio.
        public var needsRepair: Bool
        /// What the RIFF size field should hold.
        public var repairedRIFFSize: UInt32
        /// What the `data` chunk's size field should hold.
        public var repairedDataSize: UInt32
        public var sampleRate: Int
        public var channels: Int
        public var bitsPerSample: Int
        public var blockAlign: Int

        /// Where the `data` chunk's size is written.
        public var dataSizeFieldOffset: Int { dataOffset - 4 }
    }

    public enum Rejection: Error, Sendable, Hashable {
        /// The file ends inside the RIFF header, a chunk header or `fmt `.
        case headerCutShort
        /// Not a RIFF file of form type WAVE.
        case notWAVE
        /// Compressed or floating-point audio.
        case notPCM
        /// A `fmt ` chunk whose fields contradict each other, or none before `data`.
        case invalidFormat
        /// No `data` chunk within the bytes given.
        case noDataChunk
        /// More audio than a WAV header can declare.
        case tooLarge
    }

    /// `header` is the file's first bytes, at most `maximumHeaderBytes` of
    /// them, and `fileSize` its whole length on disk.
    public static func layout(header bytes: [UInt8], fileSize: Int) -> Result<Layout, Rejection> {
        func ascii(_ offset: Int) -> [UInt8] { Array(bytes[offset..<offset + 4]) }
        func uint32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        func uint16(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }

        guard bytes.count >= 12, fileSize >= bytes.count else { return .failure(.headerCutShort) }
        guard ascii(0) == Array("RIFF".utf8), ascii(8) == Array("WAVE".utf8) else { return .failure(.notWAVE) }
        let declaredRIFFSize = uint32(riffSizeFieldOffset)

        var format: (sampleRate: Int, channels: Int, bitsPerSample: Int, blockAlign: Int, byteRate: Int)?
        var offset = 12
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { return .failure(.headerCutShort) }
            let id = ascii(offset)
            let size = uint32(offset + 4)
            let body = offset + 8

            if id == Array("fmt ".utf8) {
                guard size >= 16, body + 16 <= bytes.count else { return .failure(.headerCutShort) }
                var formatTag = uint16(body)
                let channels = uint16(body + 2)
                let sampleRate = uint32(body + 4)
                let byteRate = uint32(body + 8)
                let blockAlign = uint16(body + 12)
                let bitsPerSample = uint16(body + 14)
                // WAVE_FORMAT_EXTENSIBLE names its real format in a sub-GUID.
                if formatTag == 0xFFFE {
                    guard size >= 40, body + 26 <= bytes.count else { return .failure(.headerCutShort) }
                    formatTag = uint16(body + 24)
                }
                guard formatTag == 1 else { return .failure(.notPCM) }
                guard channels > 0, sampleRate > 0, bitsPerSample > 0, bitsPerSample % 8 == 0,
                      blockAlign == channels * bitsPerSample / 8,
                      byteRate == sampleRate * blockAlign
                else { return .failure(.invalidFormat) }
                format = (sampleRate, channels, bitsPerSample, blockAlign, byteRate)
            } else if id == Array("data".utf8) {
                guard let format else { return .failure(.invalidFormat) }
                let onDisk = fileSize - body
                let declaredIsUsable = size != 0 && size != 0xFFFF_FFFF && size <= onDisk
                let payload = (declaredIsUsable ? size : onDisk) / format.blockAlign * format.blockAlign
                let dataSize = declaredIsUsable ? size : payload
                // A usable size keeps whatever follows the samples inside the
                // RIFF chunk; a rebuilt one ends the chunk at the last whole frame.
                let riffSpansData = declaredRIFFSize >= body + dataSize - 8 && declaredRIFFSize <= fileSize - 8
                let needsRepair = !declaredIsUsable || !riffSpansData
                let riffSize = !needsRepair ? declaredRIFFSize : declaredIsUsable ? fileSize - 8 : body + payload - 8
                guard dataSize <= 0xFFFF_FFFE, riffSize <= 0xFFFF_FFFE else { return .failure(.tooLarge) }
                return .success(Layout(
                    dataOffset: body,
                    payloadByteCount: payload,
                    duration: Double(payload) / Double(format.byteRate),
                    needsRepair: needsRepair,
                    repairedRIFFSize: UInt32(riffSize),
                    repairedDataSize: UInt32(dataSize),
                    sampleRate: format.sampleRate,
                    channels: format.channels,
                    bitsPerSample: format.bitsPerSample,
                    blockAlign: format.blockAlign
                ))
            }
            offset = body + size + size % 2
        }
        return .failure(.noDataChunk)
    }
}
