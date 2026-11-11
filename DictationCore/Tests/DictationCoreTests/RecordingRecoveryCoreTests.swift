import DictationCore
import Foundation
import XCTest

/// One test per row of the decision table in `RecordingRecoveryCore`, plus
/// the 0.35 s boundary, ordering, and a property test over random folders.
final class RecordingRecoveryCoreTests: XCTestCase {
    typealias Candidate = RecordingRecoveryCore.Candidate

    private let launchedAt = Date(timeIntervalSince1970: 1_000_000)
    /// The first launch that recovered, long before every default fixture.
    private let activeSince = Date(timeIntervalSince1970: 0)
    private let minimum: TimeInterval = 0.35

    private func url(_ name: String = "\(UUID().uuidString).wav") -> URL {
        URL(fileURLWithPath: "/tmp/recordings/\(name)")
    }

    /// A file that is adopted unless a test changes one fact about it.
    private func orphan(
        _ name: String = "\(UUID().uuidString).wav",
        secondsBeforeLaunch: TimeInterval = 60,
        duration: TimeInterval? = 1,
        isReferenced: Bool = false
    ) -> Candidate {
        Candidate(
            url: url(name),
            modified: launchedAt.addingTimeInterval(-secondsBeforeLaunch),
            duration: duration,
            isReferenced: isReferenced
        )
    }

    private func adopted(_ candidates: [Candidate], activeSince: Date? = nil) -> [Candidate] {
        RecordingRecoveryCore.filesToAdopt(
            candidates,
            recoveryActiveSince: activeSince ?? self.activeSince,
            launchedAt: launchedAt,
            minimumDuration: minimum
        )
    }

    func testAnUnreferencedRecordingFromBeforeLaunchIsAdopted() {
        let file = orphan()
        XCTAssertEqual(adopted([file]), [file])
    }

    func testNothingToScanAdoptsNothing() {
        XCTAssertEqual(adopted([]), [])
    }

    func testAReferencedFileIsLeftToItsRow() {
        XCTAssertEqual(adopted([orphan(isReferenced: true)]), [])
    }

    func testOnlyRecorderFileNamesAreAdopted() {
        let table: [(name: String, adopted: Bool)] = [
            ("6F9619FF-8B86-D011-B42D-00C04FC964FF.wav", true),
            ("6f9619ff-8b86-d011-b42d-00c04fc964ff.wav", true),
            ("6F9619FF-8B86-D011-B42D-00C04FC964FF.WAV", false),
            ("6F9619FF-8B86-D011-B42D-00C04FC964FF.m4a", false),
            ("6F9619FF-8B86-D011-B42D-00C04FC964FF", false),
            ("6F9619FF-8B86-D011-B42D-00C04FC964FF.wav.tmp", false),
            ("speaking-6F9619FF-8B86-D011-B42D-00C04FC964FF.wav", false),
            ("6F9619FF-8B86-D011-B42D-00C04FC964FF-copy.wav", false),
            ("6F9619FF8B86D011B42D00C04FC964FF.wav", false),
            ("recording.wav", false),
            ("12345.wav", false),
            (".wav", false),
            ("", false),
        ]
        for row in table {
            XCTAssertEqual(RecordingRecoveryCore.isRecorderFileName(row.name), row.adopted, row.name)
            XCTAssertEqual(adopted([orphan(row.name)]).count, row.adopted ? 1 : 0, row.name)
        }
    }

    func testOnlyFilesLastModifiedBeforeLaunchAreAdopted() {
        let table: [(secondsBeforeLaunch: TimeInterval, adopted: Bool)] = [
            (86_400 * 3, true),
            (60, true),
            (0.001, true),
            (0, false),
            (-0.001, false),
            (-60, false),
        ]
        for row in table {
            XCTAssertEqual(
                adopted([orphan(secondsBeforeLaunch: row.secondsBeforeLaunch)]).count, row.adopted ? 1 : 0,
                "modified \(row.secondsBeforeLaunch) s before launch"
            )
        }
    }

    func testOnlyFilesLastModifiedAfterRecoveryBecameActiveAreAdopted() {
        // Recovery became active an hour before this launch.
        let since = launchedAt.addingTimeInterval(-3_600)
        let table: [(secondsAfterActive: TimeInterval, adopted: Bool)] = [
            (-86_400 * 30, false),
            (-60, false),
            (-0.001, false),
            (0, false),
            (0.001, true),
            (60, true),
            (3_599, true),
        ]
        for row in table {
            var file = orphan()
            file.modified = since.addingTimeInterval(row.secondsAfterActive)
            XCTAssertEqual(
                adopted([file], activeSince: since).count, row.adopted ? 1 : 0,
                "modified \(row.secondsAfterActive) s after recovery became active"
            )
        }
    }

    func testTheLaunchThatMakesRecoveryActiveAdoptsNothing() {
        // No date is both after that launch and before it.
        for secondsBeforeLaunch: TimeInterval in [86_400 * 3, 60, 0.001, 0, -0.001, -60] {
            XCTAssertEqual(
                adopted([orphan(secondsBeforeLaunch: secondsBeforeLaunch)], activeSince: launchedAt), [],
                "modified \(secondsBeforeLaunch) s before launch"
            )
        }
    }

    func testAFileWithNoModificationDateIsLeft() {
        var file = orphan()
        file.modified = nil
        XCTAssertEqual(adopted([file]), [])
    }

    func testTheMinimumDurationIsTheBoundary() {
        let table: [(duration: TimeInterval?, adopted: Bool)] = [
            (nil, false),
            (0, false),
            (0.2, false),
            (0.349, false),
            (0.35, true),
            (0.351, true),
            (1, true),
            (3_600, true),
            (-1, false),
            (.nan, false),
            (.infinity, false),
        ]
        for row in table {
            XCTAssertEqual(
                adopted([orphan(duration: row.duration)]).count, row.adopted ? 1 : 0,
                "duration \(String(describing: row.duration))"
            )
        }
    }

    func testEveryFactMustHold() {
        let good = orphan()
        let mixed = [
            orphan(isReferenced: true),
            good,
            orphan(secondsBeforeLaunch: -5),
            orphan(secondsBeforeLaunch: 2_000_000),
            orphan(duration: 0.2),
            orphan(duration: nil),
            orphan("notes.txt"),
        ]
        XCTAssertEqual(adopted(mixed), [good])
    }

    func testAdoptedFilesAreOrderedOldestFirstThenByPath() {
        let newest = orphan("C0000000-0000-0000-0000-000000000000.wav", secondsBeforeLaunch: 10)
        let oldest = orphan("B0000000-0000-0000-0000-000000000000.wav", secondsBeforeLaunch: 500)
        let tiedLater = orphan("A0000000-0000-0000-0000-000000000002.wav", secondsBeforeLaunch: 100)
        let tiedFirst = orphan("A0000000-0000-0000-0000-000000000001.wav", secondsBeforeLaunch: 100)
        XCTAssertEqual(adopted([newest, tiedLater, oldest, tiedFirst]), [oldest, tiedFirst, tiedLater, newest])
    }

    /// Random folders: the result is exactly the candidates that satisfy all
    /// five facts, each once, and deciding again changes nothing.
    func testRandomFoldersAdoptExactlyTheQualifyingFiles() {
        let since = launchedAt.addingTimeInterval(-100_000)
        for seed in PropertyCheck.seeds {
            var rng = SplitMix64(seed: seed)
            var candidates: [Candidate] = []
            for _ in 0..<Int.random(in: 0...24, using: &rng) {
                let name = rng.chance(0.8) ? "\(rng.uuid().uuidString).wav" : "note-\(rng.next()).txt"
                let durations: [TimeInterval?] = [nil, 0, 0.2, 0.349, 0.35, 0.36, 2, 90]
                candidates.append(Candidate(
                    url: url(name),
                    modified: rng.chance(0.1) ? nil : launchedAt.addingTimeInterval(Double.random(in: -200_000...200, using: &rng)),
                    duration: durations.randomElement(using: &rng)!,
                    isReferenced: rng.chance(0.3)
                ))
            }

            let result = adopted(candidates, activeSince: since)

            let expected = Set(candidates.filter { candidate in
                guard let modified = candidate.modified, let duration = candidate.duration else { return false }
                return RecordingRecoveryCore.isRecorderFileName(candidate.url.lastPathComponent)
                    && !candidate.isReferenced && modified > since && modified < launchedAt && duration >= minimum
            })
            XCTAssertEqual(Set(result), expected, "seed \(seed)")
            XCTAssertEqual(result.count, expected.count, "seed \(seed): no file is adopted twice")
            XCTAssertEqual(adopted(result, activeSince: since), result, "seed \(seed): deciding again changes nothing")
            XCTAssertEqual(adopted(candidates.shuffled(using: &rng), activeSince: since), result, "seed \(seed): the scan order does not matter")
            for (earlier, later) in zip(result, result.dropFirst()) {
                XCTAssertLessThanOrEqual(earlier.modified!, later.modified!, "seed \(seed): oldest first")
            }
        }
    }
}
