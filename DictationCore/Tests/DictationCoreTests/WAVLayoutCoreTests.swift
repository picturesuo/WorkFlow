import DictationCore
import Foundation
import XCTest

/// Table tests for `WAVLayoutCore.layout` over headers built byte by byte,
/// plus a property test that a repair makes every file read as what is on
/// disk and that repairing twice changes nothing.
final class WAVLayoutCoreTests: XCTestCase {
    typealias Rejection = WAVLayoutCore.Rejection

    // MARK: - Building files

    private func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    private func le16(_ value: UInt16) -> [UInt8] { [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)] }

    private func chunk(_ id: String, _ body: [UInt8], declaredSize: UInt32? = nil) -> [UInt8] {
        Array(id.utf8) + le32(declaredSize ?? UInt32(body.count)) + body + (body.count % 2 == 1 ? [0] : [])
    }

    private func format(
        tag: UInt16 = 1, channels: UInt16 = 1, sampleRate: UInt32 = 16_000, bits: UInt16 = 16,
        blockAlign: UInt16? = nil, byteRate: UInt32? = nil, subTag: UInt16? = nil
    ) -> [UInt8] {
        let align = blockAlign ?? channels * (bits / 8)
        var body = le16(tag) + le16(channels) + le32(sampleRate) + le32(byteRate ?? sampleRate * UInt32(align)) + le16(align) + le16(bits)
        if let subTag {
            // cbSize, valid bits, channel mask, then the sub-format GUID.
            body += le16(22) + le16(bits) + le32(0) + le16(subTag) + [UInt8](repeating: 0, count: 14)
        }
        return chunk("fmt ", body)
    }

    /// A whole file: RIFF header, the chunks before `data`, the `data` chunk
    /// header, and `payload` bytes of samples.
    private func file(
        before: [UInt8]? = nil,
        payload: Int,
        declaredData: UInt32? = nil,
        declaredRIFF: UInt32? = nil,
        after: [UInt8] = []
    ) -> [UInt8] {
        let chunks = before ?? format()
        let body = Array("WAVE".utf8) + chunks + Array("data".utf8) + le32(declaredData ?? UInt32(payload))
            + [UInt8](repeating: 7, count: payload) + after
        return Array("RIFF".utf8) + le32(declaredRIFF ?? UInt32(body.count)) + body
    }

    /// What CoreAudio writes before `data`: 4,096 bytes in all.
    private var coreAudioChunks: [UInt8] {
        chunk("JUNK", [UInt8](repeating: 0, count: 28)) + format() + chunk("FLLR", [UInt8](repeating: 0, count: 4_008))
    }

    private func layout(_ bytes: [UInt8], headerBytes: Int? = nil) -> Result<WAVLayoutCore.Layout, Rejection> {
        let header = Array(bytes.prefix(headerBytes ?? WAVLayoutCore.maximumHeaderBytes))
        return WAVLayoutCore.layout(header: header, fileSize: bytes.count)
    }

    private func expectLayout(
        _ bytes: [UInt8], dataOffset: Int, payload: Int, duration: TimeInterval, needsRepair: Bool,
        riff: UInt32? = nil, data: UInt32? = nil, _ message: String = "", line: UInt = #line
    ) {
        guard case let .success(found) = layout(bytes) else {
            return XCTFail("rejected: \(layout(bytes)) \(message)", line: line)
        }
        XCTAssertEqual(found.dataOffset, dataOffset, message, line: line)
        XCTAssertEqual(found.dataSizeFieldOffset, dataOffset - 4, message, line: line)
        XCTAssertEqual(found.payloadByteCount, payload, message, line: line)
        XCTAssertEqual(found.duration, duration, accuracy: 1e-9, message, line: line)
        XCTAssertEqual(found.needsRepair, needsRepair, message, line: line)
        if let riff { XCTAssertEqual(found.repairedRIFFSize, riff, message, line: line) }
        if let data { XCTAssertEqual(found.repairedDataSize, data, message, line: line) }
    }

    // MARK: - Files that read correctly

    func testAFinishedFileNeedsNoRepair() {
        let bytes = file(payload: 32_000)
        expectLayout(bytes, dataOffset: 44, payload: 32_000, duration: 1, needsRepair: false,
                     riff: UInt32(bytes.count - 8), data: 32_000)
    }

    func testAFinishedCoreAudioFileIsWalkedPastItsFillerChunk() {
        let bytes = file(before: coreAudioChunks, payload: 16_000)
        XCTAssertEqual(bytes.count, 4_096 + 16_000)
        expectLayout(bytes, dataOffset: 4_096, payload: 16_000, duration: 0.5, needsRepair: false)
    }

    func testAChunkAfterTheSamplesIsNotCountedAsAudio() {
        let bytes = file(payload: 3_200, after: chunk("LIST", [UInt8](repeating: 1, count: 40)))
        expectLayout(bytes, dataOffset: 44, payload: 3_200, duration: 0.1, needsRepair: false, data: 3_200)
    }

    func testAnOddSizedChunkIsPaddedBeforeTheNextOne() {
        let before = format() + chunk("note", [1, 2, 3])
        let bytes = file(before: before, payload: 6_400)
        expectLayout(bytes, dataOffset: 12 + 24 + 12 + 8, payload: 6_400, duration: 0.2, needsRepair: false)
    }

    func testFormatsAreReadFromTheFormatChunk() throws {
        let stereo = file(before: format(channels: 2, sampleRate: 44_100, bits: 24), payload: 264_600)
        let found = try layout(stereo).get()
        XCTAssertEqual([found.sampleRate, found.channels, found.bitsPerSample, found.blockAlign], [44_100, 2, 24, 6])
        XCTAssertEqual(found.duration, 1, accuracy: 1e-9)
        let extensible = file(before: format(tag: 0xFFFE, subTag: 1), payload: 32_000)
        XCTAssertEqual(try layout(extensible).get().duration, 1, accuracy: 1e-9)
    }

    // MARK: - Files whose writer never stopped

    func testADataSizeOfZeroIsRebuiltFromWhatIsOnDisk() {
        // What a killed AVAudioFile writer leaves: RIFF size 4,088, data size 0.
        let bytes = file(before: coreAudioChunks, payload: 32_000, declaredData: 0, declaredRIFF: 4_088)
        expectLayout(bytes, dataOffset: 4_096, payload: 32_000, duration: 1, needsRepair: true,
                     riff: 4_096 + 32_000 - 8, data: 32_000)
    }

    func testADataSizeOfAllOnesIsRebuiltFromWhatIsOnDisk() {
        let bytes = file(payload: 16_000, declaredData: 0xFFFF_FFFF, declaredRIFF: 0xFFFF_FFFF)
        expectLayout(bytes, dataOffset: 44, payload: 16_000, duration: 0.5, needsRepair: true, riff: 44 + 16_000 - 8, data: 16_000)
    }

    func testADeclaredSizeLargerThanTheFileIsCutToWhatIsOnDisk() {
        let bytes = file(payload: 16_000, declaredData: 64_000, declaredRIFF: 64_036)
        expectLayout(bytes, dataOffset: 44, payload: 16_000, duration: 0.5, needsRepair: true, riff: 44 + 16_000 - 8, data: 16_000)
    }

    func testATrailingPartialFrameIsNotCounted() {
        let mono = file(payload: 16_001, declaredData: 0)
        expectLayout(mono, dataOffset: 44, payload: 16_000, duration: 0.5, needsRepair: true, riff: 44 + 16_000 - 8, data: 16_000)
        let stereo = file(before: format(channels: 2), payload: 64_003, declaredData: 0)
        expectLayout(stereo, dataOffset: 44, payload: 64_000, duration: 1, needsRepair: true, riff: 44 + 64_000 - 8, data: 64_000)
    }

    func testAnEmptyDataChunkHoldsNoAudio() {
        expectLayout(file(payload: 0), dataOffset: 44, payload: 0, duration: 0, needsRepair: true, data: 0)
    }

    func testARIFFSizeThatDoesNotSpanTheSamplesIsRepairedAlone() {
        let table: [(riff: UInt32, needsRepair: Bool)] = [
            (0, true),
            (4, true),
            (16_035, true),
            (16_036, false),
            (16_037, true),
            (0xFFFF_FFFF, true),
        ]
        for row in table {
            let bytes = file(payload: 16_000, declaredRIFF: row.riff)
            XCTAssertEqual(bytes.count, 16_044)
            expectLayout(bytes, dataOffset: 44, payload: 16_000, duration: 0.5, needsRepair: row.needsRepair,
                         riff: 16_036, data: 16_000, "RIFF size \(row.riff)")
        }
    }

    func testTheDurationComesFromTheByteRate() {
        let table: [(before: [UInt8], payload: Int, duration: TimeInterval)] = [
            (format(), 11_200, 0.35),
            (format(), 11_198, 0.3499375),
            (format(channels: 2, sampleRate: 48_000), 192_000, 1),
            (format(sampleRate: 8_000, bits: 8), 4_000, 0.5),
        ]
        for row in table {
            expectLayout(file(before: row.before, payload: row.payload, declaredData: 0), dataOffset: 44,
                         payload: row.payload, duration: row.duration, needsRepair: true)
        }
    }

    // MARK: - Files that are rejected

    func testFilesThatAreNotPCMWAVEAreRejected() {
        var avi = file(payload: 16_000)
        avi.replaceSubrange(8..<12, with: Array("AVI ".utf8))
        var rf64 = file(payload: 16_000)
        rf64.replaceSubrange(0..<4, with: Array("RF64".utf8))
        let table: [(name: String, bytes: [UInt8], rejection: Rejection)] = [
            ("empty", [], .headerCutShort),
            ("eight bytes", Array("RIFF".utf8) + le32(0), .headerCutShort),
            ("text", Array("these bytes are not audio at all".utf8), .notWAVE),
            ("AVI", avi, .notWAVE),
            ("RF64", rf64, .notWAVE),
            ("float", file(before: format(tag: 3, bits: 32), payload: 64_000), .notPCM),
            ("MP3 in WAV", file(before: format(tag: 0x55), payload: 16_000), .notPCM),
            ("extensible float", file(before: format(tag: 0xFFFE, bits: 32, subTag: 3), payload: 64_000), .notPCM),
            ("no channels", file(before: format(channels: 0, blockAlign: 2, byteRate: 32_000), payload: 16_000), .invalidFormat),
            ("no sample rate", file(before: format(sampleRate: 0), payload: 16_000), .invalidFormat),
            ("block align disagrees", file(before: format(blockAlign: 3), payload: 16_000), .invalidFormat),
            ("byte rate disagrees", file(before: format(byteRate: 1), payload: 16_000), .invalidFormat),
            ("twelve-bit samples", file(before: format(bits: 12, blockAlign: 2), payload: 16_000), .invalidFormat),
            ("data before fmt", file(before: [], payload: 16_000), .invalidFormat),
        ]
        for row in table {
            XCTAssertEqual(layout(row.bytes), .failure(row.rejection), row.name)
        }
    }

    func testAFileWithNoDataChunkIsRejected() {
        let onlyFormat = Array("RIFF".utf8) + le32(28) + Array("WAVE".utf8) + format()
        XCTAssertEqual(layout(onlyFormat), .failure(.noDataChunk))
        let onlyHeader = Array("RIFF".utf8) + le32(4) + Array("WAVE".utf8)
        XCTAssertEqual(layout(onlyHeader), .failure(.noDataChunk))
        // The data chunk exists, but beyond the bytes the caller read.
        let bytes = file(before: coreAudioChunks, payload: 16_000)
        XCTAssertEqual(layout(bytes, headerBytes: 4_088), .failure(.noDataChunk))
        XCTAssertNoThrow(try layout(bytes, headerBytes: 4_096).get())
    }

    func testAHeaderCutShortIsRejectedWhereverItEnds() throws {
        let whole = file(before: coreAudioChunks, payload: 0)
        XCTAssertEqual(whole.count, 4_096)
        XCTAssertNoThrow(try layout(whole).get())
        // Cut inside the RIFF header, a chunk header, and the fmt body.
        for length in [0, 4, 11, 13, 19, 49, 56, 60, 71, 4_090, 4_095] {
            XCTAssertEqual(layout(Array(whole.prefix(length))), .failure(.headerCutShort), "cut at \(length)")
        }
        // Cut between chunks: nothing is half written, there is just no data yet.
        for length in [12, 48, 72, 4_088] {
            XCTAssertEqual(layout(Array(whole.prefix(length))), .failure(.noDataChunk), "cut at \(length)")
        }
    }

    func testMoreAudioThanAHeaderCanDeclareIsRejected() {
        let header = Array(file(payload: 0, declaredData: 0).prefix(44))
        XCTAssertEqual(WAVLayoutCore.layout(header: header, fileSize: 44 + 0x1_0000_0000), .failure(.tooLarge))
        XCTAssertNoThrow(try WAVLayoutCore.layout(header: header, fileSize: 44 + 0xFFFF_0000).get())
    }

    // MARK: - Property

    /// Random PCM files with random declared sizes: the layout never claims
    /// bytes that are not on disk, and writing the two repaired sizes makes
    /// the file declare exactly that audio and need no further repair.
    func testARepairDeclaresExactlyTheWholeFramesOnDiskAndIsStable() throws {
        for seed in PropertyCheck.seeds {
            var rng = SplitMix64(seed: seed)
            let channels = UInt16.random(in: 1...2, using: &rng)
            let bits: UInt16 = [8, 16, 24].randomElement(using: &rng)!
            let align = Int(channels * bits / 8)
            let before = rng.chance(0.5) ? format(channels: channels, bits: bits)
                : chunk("JUNK", [UInt8](repeating: 0, count: Int.random(in: 0...31, using: &rng)))
                    + format(channels: channels, bits: bits)
                    + chunk("FLLR", [UInt8](repeating: 0, count: Int.random(in: 0...200, using: &rng)))
            let payload = Int.random(in: 0...4_000, using: &rng)
            let declaredData: UInt32 = [0, 0xFFFF_FFFF, UInt32(payload), UInt32(payload) + 1, UInt32(payload / 2), 1_000_000]
                .randomElement(using: &rng)!
            let declaredRIFF: UInt32? = rng.chance(0.5) ? nil : [0, 4_088, 0xFFFF_FFFF, UInt32.random(in: 0...6_000, using: &rng)]
                .randomElement(using: &rng)!
            var bytes = file(before: before, payload: payload, declaredData: declaredData, declaredRIFF: declaredRIFF)
            let found = try layout(bytes).get()

            XCTAssertEqual(found.payloadByteCount % align, 0, "seed \(seed): whole frames only")
            XCTAssertLessThanOrEqual(found.dataOffset + found.payloadByteCount, bytes.count, "seed \(seed): on disk")
            XCTAssertEqual(found.duration * Double(found.sampleRate * align), Double(found.payloadByteCount), accuracy: 1e-6)
            let declaredIsUsable = declaredData != 0 && declaredData != 0xFFFF_FFFF && Int(declaredData) <= payload
            if declaredIsUsable {
                XCTAssertEqual(found.payloadByteCount, Int(declaredData) / align * align, "seed \(seed): the declared size is kept")
            } else {
                XCTAssertEqual(found.payloadByteCount, payload / align * align, "seed \(seed): everything on disk")
                XCTAssertTrue(found.needsRepair, "seed \(seed)")
            }

            bytes.replaceSubrange(4..<8, with: le32(found.repairedRIFFSize))
            bytes.replaceSubrange(found.dataSizeFieldOffset..<found.dataOffset, with: le32(found.repairedDataSize))
            let repaired = try layout(bytes).get()
            XCTAssertEqual(repaired.payloadByteCount, found.payloadByteCount, "seed \(seed): the same audio")
            XCTAssertEqual(repaired.dataOffset, found.dataOffset, "seed \(seed)")
            if found.payloadByteCount > 0 {
                XCTAssertFalse(repaired.needsRepair, "seed \(seed): repairing twice changes nothing")
                XCTAssertEqual(repaired.repairedRIFFSize, found.repairedRIFFSize, "seed \(seed)")
                XCTAssertEqual(repaired.repairedDataSize, found.repairedDataSize, "seed \(seed)")
            }
            if !found.needsRepair {
                XCTAssertEqual(found.repairedDataSize, declaredData, "seed \(seed): a file that reads correctly keeps its sizes")
            }
        }
    }
}
