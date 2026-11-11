import Foundation

/// Decides which temporary recordings a launch adopts into History.
///
/// A dictation reaches History only after transcription, cleanup and paste,
/// so a process that dies before then leaves only its temporary audio file.
/// At launch every file in the temporary recordings folder is offered here,
/// and the ones returned become failed History rows the user can regenerate.
/// Everything else is left exactly where it is for the 24-hour sweep.
///
/// Decision table. A file is adopted only when every row says so:
///
/// | Fact | Adopted | Left in place because |
/// |---|---|---|
/// | name | is `<UUID>.wav` | the recorder did not write it |
/// | History reference | none | a row already owns it |
/// | last modified | before this process launched | this process may still be writing it, or the date is unknown |
/// | audio duration | at least `minimumDuration` | it is too short to be a recording, or is not readable audio |
///
/// The result is ordered oldest first, then by path, so the rows are added
/// to History in the order they were recorded.
public enum RecordingRecoveryCore {
    /// One file found in the temporary recordings folder.
    public struct Candidate: Sendable, Hashable {
        public var url: URL
        /// When the file was last written; nil when the file system cannot say.
        public var modified: Date?
        /// Seconds of audio in the file; nil when it cannot be read as audio.
        public var duration: TimeInterval?
        /// Whether a History or queue row points at this file.
        public var isReferenced: Bool

        public init(url: URL, modified: Date?, duration: TimeInterval?, isReferenced: Bool) {
            self.url = url
            self.modified = modified
            self.duration = duration
            self.isReferenced = isReferenced
        }
    }

    /// True for the names the recorder gives its files: `<UUID>.wav`.
    public static func isRecorderFileName(_ name: String) -> Bool {
        let suffix = ".wav"
        guard name.hasSuffix(suffix) else { return false }
        let stem = name.dropLast(suffix.count)
        // Only the 36-character hyphenated form, the one the recorder writes.
        return stem.count == 36 && UUID(uuidString: String(stem)) != nil
    }

    /// The files to adopt, oldest first.
    public static func filesToAdopt(
        _ candidates: [Candidate],
        launchedAt: Date,
        minimumDuration: TimeInterval
    ) -> [Candidate] {
        let adopted: [(candidate: Candidate, modified: Date)] = candidates.compactMap { candidate in
            guard isRecorderFileName(candidate.url.lastPathComponent),
                  !candidate.isReferenced,
                  let modified = candidate.modified, modified < launchedAt,
                  let duration = candidate.duration, duration.isFinite, duration >= minimumDuration
            else { return nil }
            return (candidate, modified)
        }
        return adopted
            .sorted { first, second in
                first.modified != second.modified
                    ? first.modified < second.modified
                    : first.candidate.url.path < second.candidate.url.path
            }
            .map(\.candidate)
    }
}
