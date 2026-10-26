import Foundation
import GRDB

/// What happened to a dictation's text when it was emitted. A synthesized
/// Cmd+V only proves the keystroke was posted, never that the target app
/// inserted the text, so no case claims a confirmed insertion.
enum DictationDisposition: String, Codable, Equatable {
    /// Queued and not yet transcribed.
    case pending
    /// Cmd+V was posted to the target app; delivery is not confirmed.
    case pasteSent = "paste_sent"
    case pasteFailed = "paste_failed"
    case copiedOnly = "copied_only"
    /// Saved to History only, by an app rule or with paste and copy off.
    case savedOnly = "saved_only"
    /// A newer dictation started first, so this one was saved without pasting.
    case staleSkipped = "stale_skipped"
    /// Esc after the recording stopped: saved without pasting.
    case cancelled
    /// A path that never pastes: the main window, imports, and the queue.
    case notInserted = "not_inserted"
}

/// The local, original evidence for one new dictation, kept on this Mac with
/// its History row and deleted with it. Rows recorded before this table
/// existed have none and are legacy History: only their final text is known.
struct DictationSource: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "dictation_sources"

    let recordingID: UUID
    var capturedAt: Date
    var recordingStartedAt: Date?
    /// The speech recognizer's words, before vocabulary or cleanup.
    var recognizerText: String?
    /// What cleanup received, stored only where vocabulary changed it.
    var cleanupInputText: String?
    /// The text WorkFlow produced and saved for this dictation.
    var emittedText: String?
    /// The exact string handed to paste or copy, if delivery was attempted.
    var insertedText: String?
    var disposition: DictationDisposition
    /// The mode selected for this dictation, kept even when cleanup was off.
    var selectedMode: CleanupMode
    var filterID: UUID?
    var filterName: String?
    var filterInstructions: String?
    var filterWritesDigits: Bool
    var learnedPreferences: [LearnedPreference]
    var cleanupSource: TranscriptCleanupOutcome.Source?

    init(
        recordingID: UUID,
        capturedAt: Date = Date(),
        recordingStartedAt: Date? = nil,
        recognizerText: String? = nil,
        cleanupInputText: String? = nil,
        emittedText: String? = nil,
        insertedText: String? = nil,
        disposition: DictationDisposition,
        filter: CleanupFilterSnapshot,
        cleanupSource: TranscriptCleanupOutcome.Source? = nil
    ) {
        self.recordingID = recordingID
        self.capturedAt = capturedAt
        self.recordingStartedAt = recordingStartedAt
        self.recognizerText = recognizerText
        self.cleanupInputText = cleanupInputText == recognizerText ? nil : cleanupInputText
        self.emittedText = emittedText
        self.insertedText = insertedText
        self.disposition = disposition
        self.selectedMode = filter.mode
        self.filterID = filter.customID
        self.filterName = filter.customName
        self.filterInstructions = filter.customInstructions
        self.filterWritesDigits = filter.customWritesDigits
        self.learnedPreferences = filter.learned
        self.cleanupSource = cleanupSource
    }

    /// Evidence for a dictation whose cleanup has finished.
    init(
        recordingID: UUID,
        recordingStartedAt: Date? = nil,
        recognizerText: String,
        cleanup: TranscriptCleanupOutcome,
        fallbackFilter: CleanupFilterSnapshot,
        disposition: DictationDisposition,
        insertedText: String? = nil
    ) {
        self.init(
            recordingID: recordingID,
            recordingStartedAt: recordingStartedAt,
            recognizerText: recognizerText,
            cleanupInputText: cleanup.cleanupInput,
            emittedText: cleanup.text,
            insertedText: insertedText,
            disposition: disposition,
            filter: cleanup.selectedFilter ?? fallbackFilter,
            cleanupSource: cleanup.source
        )
    }

    /// The text cleanup saw: the vocabulary-rewritten input when it differs,
    /// otherwise the recognizer's own words.
    var cleanupInput: String? { cleanupInputText ?? recognizerText }

    /// The filter selected for this dictation, as captured.
    var filter: CleanupFilterSnapshot {
        CleanupFilterSnapshot(
            mode: selectedMode,
            customName: filterName,
            customInstructions: filterInstructions,
            customID: filterID,
            customWritesDigits: filterWritesDigits,
            learned: learnedPreferences
        )
    }

    enum Columns {
        static let recordingID = Column(CodingKeys.recordingID)
        static let recognizerText = Column(CodingKeys.recognizerText)
        static let cleanupInputText = Column(CodingKeys.cleanupInputText)
        static let emittedText = Column(CodingKeys.emittedText)
        static let disposition = Column(CodingKeys.disposition)
        static let cleanupSource = Column(CodingKeys.cleanupSource)
    }
}
