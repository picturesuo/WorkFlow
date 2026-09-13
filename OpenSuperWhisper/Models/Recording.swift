import Foundation
import GRDB

enum RecordingStatus: String, Codable {
    case pending
    case converting
    case transcribing
    case completed
    case failed
}

enum RecordingMode: String, Codable {
    case dictation
    case meeting
}

struct Recording: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable {
    let id: UUID
    let timestamp: Date
    let fileName: String
    var transcription: String
    let duration: TimeInterval
    var status: RecordingStatus
    var progress: Float
    var sourceFileURL: String?
    var cleanupSource: TranscriptCleanupOutcome.Source? = nil
    var cleanupInputTokens: Int? = nil
    var cleanupOutputTokens: Int? = nil
    var cleanupModelID: String? = nil
    var title: String? = nil
    var mode: RecordingMode = .dictation
    var cleanupRequested: Bool = false
    var targetBundleID: String? = nil
    var cleanupMode: CleanupMode? = nil
    var rawTokenEstimate: Int? = nil
    var finalTokenEstimate: Int? = nil
    var tokenEstimatorID: String? = nil
    
    var isRegeneration: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case id, timestamp, fileName, transcription, duration, status, progress, sourceFileURL
        case cleanupSource, cleanupInputTokens, cleanupOutputTokens, cleanupModelID
        case title, mode, cleanupRequested, targetBundleID
        case cleanupMode, rawTokenEstimate, finalTokenEstimate, tokenEstimatorID
    }

    static func == (lhs: Recording, rhs: Recording) -> Bool {
        return lhs.id == rhs.id &&
               lhs.status == rhs.status &&
               lhs.progress == rhs.progress &&
               lhs.transcription == rhs.transcription &&
               lhs.cleanupSource == rhs.cleanupSource &&
               lhs.cleanupInputTokens == rhs.cleanupInputTokens &&
               lhs.cleanupOutputTokens == rhs.cleanupOutputTokens &&
               lhs.cleanupModelID == rhs.cleanupModelID &&
               lhs.title == rhs.title &&
               lhs.mode == rhs.mode &&
               lhs.cleanupRequested == rhs.cleanupRequested &&
               lhs.targetBundleID == rhs.targetBundleID &&
               lhs.cleanupMode == rhs.cleanupMode &&
               lhs.rawTokenEstimate == rhs.rawTokenEstimate &&
               lhs.finalTokenEstimate == rhs.finalTokenEstimate &&
               lhs.tokenEstimatorID == rhs.tokenEstimatorID &&
               lhs.isRegeneration == rhs.isRegeneration
    }

    static var recordingsDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let appDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!)
        return appDirectory.appendingPathComponent("recordings")
    }

    var url: URL {
        Self.recordingsDirectory.appendingPathComponent(fileName)
    }
    
    var isPending: Bool {
        status == .pending || status == .converting || status == .transcribing
    }
    
    var sourceFileName: String? {
        guard let sourceFileURL = sourceFileURL else { return nil }
        return URL(fileURLWithPath: sourceFileURL).lastPathComponent
    }

    static let databaseTableName = "recordings"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let timestamp = Column(CodingKeys.timestamp)
        static let fileName = Column(CodingKeys.fileName)
        static let transcription = Column(CodingKeys.transcription)
        static let duration = Column(CodingKeys.duration)
        static let status = Column(CodingKeys.status)
        static let progress = Column(CodingKeys.progress)
        static let sourceFileURL = Column(CodingKeys.sourceFileURL)
        static let cleanupSource = Column(CodingKeys.cleanupSource)
        static let cleanupInputTokens = Column(CodingKeys.cleanupInputTokens)
        static let cleanupOutputTokens = Column(CodingKeys.cleanupOutputTokens)
        static let cleanupModelID = Column(CodingKeys.cleanupModelID)
        static let title = Column(CodingKeys.title)
        static let mode = Column(CodingKeys.mode)
        static let cleanupRequested = Column(CodingKeys.cleanupRequested)
        static let targetBundleID = Column(CodingKeys.targetBundleID)
        static let cleanupMode = Column(CodingKeys.cleanupMode)
        static let rawTokenEstimate = Column(CodingKeys.rawTokenEstimate)
        static let finalTokenEstimate = Column(CodingKeys.finalTokenEstimate)
        static let tokenEstimatorID = Column(CodingKeys.tokenEstimatorID)
    }
}

struct BedrockUsageSummary: Equatable {
    var cleanedDictations = 0
    var fallbackDictations = 0
    var inputTokens = 0
    var outputTokens = 0
    var estimatedCostUSD = 0.0
    var unpricedDictations = 0
    var localCleanedDictations = 0
}

@MainActor
class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    @Published private(set) var recordings: [Recording] = []
    private let dbQueue: DatabaseQueue
    private let recordingsDirectory: URL
    private let cancelQueuedRecording: (UUID) -> Void
    private let stopPlayback: ([URL]) -> Void

    private convenience init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let appDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!)
        let dbPath = appDirectory.appendingPathComponent("recordings.sqlite")

        do {
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            try self.init(
                database: DatabaseQueue(path: dbPath.path),
                recordingsDirectory: appDirectory.appendingPathComponent("recordings"),
                cancelQueuedRecording: { TranscriptionQueue.shared.cancelRecording($0) },
                stopPlayback: { urls in
                    let recorder = AudioRecorder.shared
                    if let playingURL = recorder.currentlyPlayingURL,
                       urls.contains(playingURL.standardizedFileURL) {
                        recorder.stopPlaying()
                    }
                }
            )
        } catch {
            fatalError("Failed to set up the recording database.")
        }
    }

    init(
        database: DatabaseQueue,
        recordingsDirectory: URL,
        cancelQueuedRecording: @escaping (UUID) -> Void,
        stopPlayback: @escaping ([URL]) -> Void
    ) throws {
        self.dbQueue = database
        self.recordingsDirectory = recordingsDirectory.standardizedFileURL
        self.cancelQueuedRecording = cancelQueuedRecording
        self.stopPlayback = stopPlayback
        try setupDatabase()
    }

    private nonisolated func setupDatabase() throws {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("v1") { db in
            try db.create(table: Recording.databaseTableName, ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("fileName", .text).notNull()
                t.column("transcription", .text).notNull().indexed().collate(.nocase)
                t.column("duration", .double).notNull()
            }
        }
        
        migrator.registerMigration("v2_add_status") { db in
            let columns = try db.columns(in: Recording.databaseTableName)
            let columnNames = columns.map { $0.name }
            
            if !columnNames.contains("status") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "status", .text).notNull().defaults(to: "completed")
                }
            }
            if !columnNames.contains("progress") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "progress", .double).notNull().defaults(to: 1.0)
                }
            }
            if !columnNames.contains("sourceFileURL") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "sourceFileURL", .text)
                }
            }
        }

        migrator.registerMigration("v3_add_cleanup_metadata") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map(\.name)
            if !columnNames.contains("cleanupSource") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "cleanupSource", .text)
                }
            }
            if !columnNames.contains("cleanupInputTokens") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "cleanupInputTokens", .integer)
                }
            }
            if !columnNames.contains("cleanupOutputTokens") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "cleanupOutputTokens", .integer)
                }
            }
            if !columnNames.contains("cleanupModelID") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "cleanupModelID", .text)
                }
            }
        }

        migrator.registerMigration("v4_add_recording_context") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map(\.name)
            if !columnNames.contains("title") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "title", .text)
                }
            }
            if !columnNames.contains("mode") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "mode", .text).notNull().defaults(to: RecordingMode.dictation.rawValue)
                }
            }
            if !columnNames.contains("cleanupRequested") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "cleanupRequested", .boolean).notNull().defaults(to: false)
                }
            }
        }

        migrator.registerMigration("v5_add_target_app") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map(\.name)
            if !columnNames.contains("targetBundleID") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "targetBundleID", .text)
                }
            }
        }

        migrator.registerMigration("v6_add_cleanup_efficiency") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map(\.name)
            if !columnNames.contains("cleanupMode") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "cleanupMode", .text)
                }
            }
            if !columnNames.contains("rawTokenEstimate") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "rawTokenEstimate", .integer)
                }
            }
            if !columnNames.contains("finalTokenEstimate") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "finalTokenEstimate", .integer)
                }
            }
            if !columnNames.contains("tokenEstimatorID") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.add(column: "tokenEstimatorID", .text)
                }
            }
        }

        // A prerelease 0.5 build briefly stored a duplicate raw transcript.
        // The efficiency feature needs only counts, so remove that private
        // preview column for anyone who ran the prerelease build.
        migrator.registerMigration("v7_remove_preview_raw_transcription") { db in
            let columnNames = try db.columns(in: Recording.databaseTableName).map(\.name)
            if columnNames.contains("rawTranscription") {
                try db.alter(table: Recording.databaseTableName) { t in
                    t.drop(column: "rawTranscription")
                }
            }
        }
        
        try migrator.migrate(dbQueue)
    }
    
    private nonisolated func fetchAllRecordings() async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .order(Recording.Columns.timestamp.desc)
                .fetchAll(db)
        }
    }
    
    nonisolated func fetchRecordings(limit: Int, offset: Int) async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .order(Recording.Columns.timestamp.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    nonisolated func bedrockUsage(since startDate: Date) async throws -> BedrockUsageSummary {
        let recentRecordings = try await dbQueue.read { db in
            try Recording
                .filter(Recording.Columns.timestamp >= startDate)
                .fetchAll(db)
        }

        return recentRecordings.reduce(into: BedrockUsageSummary()) { summary, recording in
            switch recording.cleanupSource {
            case .bedrock:
                summary.cleanedDictations += 1
                summary.inputTokens += recording.cleanupInputTokens ?? 0
                summary.outputTokens += recording.cleanupOutputTokens ?? 0
                if let modelID = recording.cleanupModelID,
                   let estimate = BedrockPricing.estimateUSD(
                       modelID: modelID,
                       inputTokens: recording.cleanupInputTokens,
                       outputTokens: recording.cleanupOutputTokens
                   ) {
                    summary.estimatedCostUSD += estimate
                } else {
                    summary.unpricedDictations += 1
                }
            case .ollama:
                summary.cleanedDictations += 1
                summary.localCleanedDictations += 1
                summary.inputTokens += recording.cleanupInputTokens ?? 0
                summary.outputTokens += recording.cleanupOutputTokens ?? 0
            case .openAICompatible:
                summary.cleanedDictations += 1
                summary.unpricedDictations += 1
                summary.inputTokens += recording.cleanupInputTokens ?? 0
                summary.outputTokens += recording.cleanupOutputTokens ?? 0
            case .rawFallback:
                summary.fallbackDictations += 1
                summary.inputTokens += recording.cleanupInputTokens ?? 0
                summary.outputTokens += recording.cleanupOutputTokens ?? 0
                if let modelID = recording.cleanupModelID,
                   let estimate = BedrockPricing.estimateUSD(
                       modelID: modelID,
                       inputTokens: recording.cleanupInputTokens,
                       outputTokens: recording.cleanupOutputTokens
                   ) {
                    summary.estimatedCostUSD += estimate
                }
            case .budgetLimited:
                summary.fallbackDictations += 1
            case .disabled, nil:
                break
            }
        }
    }

    nonisolated func tokenEfficiency(since startDate: Date) async throws -> TokenEfficiencySummary {
        let recentRecordings = try await dbQueue.read { db in
            try Recording
                .filter(Recording.Columns.timestamp >= startDate)
                .fetchAll(db)
        }
        let samples = recentRecordings.compactMap { recording -> TokenEfficiencySample? in
            guard recording.tokenEstimatorID == LocalTokenEstimator.identifier,
                  let mode = recording.cleanupMode,
                  let sourceTokens = recording.rawTokenEstimate,
                  let finalTokens = recording.finalTokenEstimate else { return nil }
            switch recording.cleanupSource {
            case .bedrock, .ollama, .openAICompatible:
                return TokenEfficiencySample(
                    mode: mode,
                    sourceTokens: sourceTokens,
                    finalTokens: finalTokens
                )
            case .rawFallback, .budgetLimited, .disabled, nil:
                return nil
            }
        }
        return TokenEfficiencyCalculator.summarize(samples)
    }

    func getPendingRecordings() -> [Recording] {
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter([RecordingStatus.pending.rawValue, RecordingStatus.converting.rawValue, RecordingStatus.transcribing.rawValue].contains(Recording.Columns.status))
                    .order(Recording.Columns.timestamp.asc)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to get pending recordings.")
            return []
        }
    }

    func getNextPendingRecording() -> Recording? {
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter([RecordingStatus.pending.rawValue, RecordingStatus.converting.rawValue, RecordingStatus.transcribing.rawValue].contains(Recording.Columns.status))
                    .order(Recording.Columns.timestamp.asc)
                    .limit(1)
                    .fetchOne(db)
            }
        } catch {
            print("Failed to get the next pending recording.")
            return nil
        }
    }

    static let recordingsDidUpdateNotification = Notification.Name("RecordingStore.recordingsDidUpdate")

    func addRecording(_ recording: Recording) {
        Task {
            do {
                try await insertRecording(recording)
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                print("Failed to add recording.")
            }
        }
    }
    
    func addRecordingSync(_ recording: Recording) async throws {
        try await insertRecording(recording)
        await MainActor.run {
            NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
        }
    }
    
    private nonisolated func insertRecording(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            try recording.insert(db)
        }
    }
    
    func updateRecording(_ recording: Recording) {
        Task {
            do {
                try await updateRecordingInDB(recording)
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
                }
            } catch {
                print("Failed to update recording.")
            }
        }
    }
    
    func updateRecordingSync(_ recording: Recording) async throws {
        try await updateRecordingInDB(recording)
        await MainActor.run {
            NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
        }
    }
    
    func updateRecordingProgressOnly(_ id: UUID, transcription: String, progress: Float, status: RecordingStatus) {
        Task {
            await updateRecordingProgressOnlySync(id, transcription: transcription, progress: progress, status: status)
        }
    }
    
    static let recordingProgressDidUpdateNotification = Notification.Name("RecordingStore.recordingProgressDidUpdate")
    
    /// Updates the in-memory copy and notifies observers without touching the database.
    private func applyLocalProgressUpdate(
        _ id: UUID,
        transcription: String? = nil,
        progress: Float,
        status: RecordingStatus,
        isRegeneration: Bool? = nil,
        cleanup: TranscriptCleanupOutcome? = nil
    ) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            var updated = recordings[index]
            if let transcription = transcription {
                updated.transcription = transcription
            }
            updated.progress = progress
            updated.status = status
            if let isRegeneration = isRegeneration {
                updated.isRegeneration = isRegeneration
            }
            if let cleanup = cleanup {
                updated.cleanupSource = cleanup.source
                updated.cleanupInputTokens = cleanup.inputTokens
                updated.cleanupOutputTokens = cleanup.outputTokens
                updated.cleanupModelID = cleanup.modelID
                updated.cleanupMode = cleanup.cleanupMode
                updated.rawTokenEstimate = cleanup.rawTokenEstimate
                updated.finalTokenEstimate = cleanup.finalTokenEstimate
                updated.tokenEstimatorID = cleanup.tokenEstimatorID
            }
            recordings[index] = updated
        }
        
        var userInfo: [String: Any] = [
            "id": id,
            "progress": progress,
            "status": status
        ]
        if let transcription = transcription {
            userInfo["transcription"] = transcription
        }
        if let isRegeneration = isRegeneration {
            userInfo["isRegeneration"] = isRegeneration
        }
        
        NotificationCenter.default.post(name: Self.recordingProgressDidUpdateNotification, object: nil, userInfo: userInfo)
    }
    
    /// Progress ticks are ephemeral UI state: persisting each one caused up to
    /// ~100 SQLite transactions per transcription. Status transitions are still
    /// persisted by the explicit update methods.
    func updateRecordingProgressTransient(_ id: UUID, progress: Float, status: RecordingStatus) {
        applyLocalProgressUpdate(id, progress: progress, status: status)
    }
    
    func updateRecordingProgressOnlySync(_ id: UUID, transcription: String, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil) async {
        do {
            _ = try await dbQueue.write { db -> Int in
                try Recording
                    .filter(Recording.Columns.id == id)
                    .updateAll(db, [
                        Recording.Columns.transcription.set(to: transcription),
                        Recording.Columns.progress.set(to: progress),
                        Recording.Columns.status.set(to: status.rawValue)
                    ])
            }
            applyLocalProgressUpdate(id, transcription: transcription, progress: progress, status: status, isRegeneration: isRegeneration)
        } catch {
            print("Failed to update recording progress.")
        }
    }

    func completeRecording(_ id: UUID, transcription: String, cleanup: TranscriptCleanupOutcome) async {
        do {
            _ = try await dbQueue.write { db -> Int in
                try Recording
                    .filter(Recording.Columns.id == id)
                    .updateAll(db, [
                        Recording.Columns.transcription.set(to: transcription),
                        Recording.Columns.progress.set(to: 1.0),
                        Recording.Columns.status.set(to: RecordingStatus.completed.rawValue),
                        Recording.Columns.cleanupSource.set(to: cleanup.source.rawValue),
                        Recording.Columns.cleanupInputTokens.set(to: cleanup.inputTokens),
                        Recording.Columns.cleanupOutputTokens.set(to: cleanup.outputTokens),
                        Recording.Columns.cleanupModelID.set(to: cleanup.modelID),
                        Recording.Columns.cleanupMode.set(to: cleanup.cleanupMode?.rawValue),
                        Recording.Columns.rawTokenEstimate.set(to: cleanup.rawTokenEstimate),
                        Recording.Columns.finalTokenEstimate.set(to: cleanup.finalTokenEstimate),
                        Recording.Columns.tokenEstimatorID.set(to: cleanup.tokenEstimatorID)
                    ])
            }
            applyLocalProgressUpdate(
                id,
                transcription: transcription,
                progress: 1,
                status: .completed,
                isRegeneration: false,
                cleanup: cleanup
            )
            NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
        } catch {
            print("Failed to complete recording.")
        }
    }

    nonisolated func updateSourceFileURL(_ id: UUID, sourceURL: String) async throws {
        try await dbQueue.write { db in
            try Recording
                .filter(Recording.Columns.id == id)
                .updateAll(db, [
                    Recording.Columns.sourceFileURL.set(to: sourceURL)
                ])
        }
    }

    func updateCleanupRequested(_ id: UUID, cleanupRequested: Bool) async {
        do {
            _ = try await dbQueue.write { db -> Int in
                try Recording
                    .filter(Recording.Columns.id == id)
                    .updateAll(db, [Recording.Columns.cleanupRequested.set(to: cleanupRequested)])
            }
            if let index = recordings.firstIndex(where: { $0.id == id }) {
                recordings[index].cleanupRequested = cleanupRequested
            }
        } catch {
            print("Failed to update the cleanup preference.")
        }
    }

    func updateRecordingStatusOnly(_ id: UUID, progress: Float, status: RecordingStatus, isRegeneration: Bool? = nil) async {
        do {
            _ = try await dbQueue.write { db -> Int in
                try Recording
                    .filter(Recording.Columns.id == id)
                    .updateAll(db, [
                        Recording.Columns.progress.set(to: progress),
                        Recording.Columns.status.set(to: status.rawValue)
                    ])
            }
            applyLocalProgressUpdate(id, progress: progress, status: status, isRegeneration: isRegeneration)
        } catch {
            print("Failed to update recording status.")
        }
    }

    private nonisolated func updateRecordingInDB(_ recording: Recording) async throws {
        try await dbQueue.write { db in
            try recording.update(db)
        }
    }

    func deleteRecording(_ recording: Recording) {
        Task {
            do {
                try await deleteRecordingSync(recording)
            } catch {
                print("Failed to delete recording.")
            }
        }
    }

    func deleteRecordingSync(_ recording: Recording) async throws {
        let deleted = try await dbQueue.write { db in
            let request = Recording.filter(Recording.Columns.id == recording.id)
            let deleted = try request.fetchAll(db)
            _ = try request.deleteAll(db)
            return deleted
        }
        await finishDeleting(deleted)
    }

    func deleteAllRecordings() {
        Task {
            do {
                try await deleteAllRecordingsSync()
            } catch {
                print("Failed to delete all recordings.")
            }
        }
    }

    func deleteAllRecordingsSync() async throws {
        let deleted = try await deleteRecordingsFromDB(olderThan: nil)
        await finishDeleting(deleted)
    }

    /// Select and delete in one transaction, so audio cleanup only receives
    /// rows whose deletion actually committed, never a stale read snapshot.
    private nonisolated func deleteRecordingsFromDB(olderThan cutoff: Date?) async throws -> [Recording] {
        try await dbQueue.write { db in
            var request = Recording.all()
            if let cutoff {
                request = request
                    .filter(Recording.Columns.timestamp < cutoff)
                    .filter(!Self.pendingStatuses.contains(Recording.Columns.status))
            }
            let deleted = try request.fetchAll(db)
            _ = try request.deleteAll(db)
            return deleted
        }
    }

    private func finishDeleting(_ deleted: [Recording]) async {
        guard !deleted.isEmpty else { return }
        for recording in deleted where recording.isPending {
            cancelQueuedRecording(recording.id)
        }
        let directoryPath = recordingsDirectory.path
        let urls = deleted.map {
            recordingsDirectory.appendingPathComponent($0.fileName).standardizedFileURL
        }.filter { $0.path.hasPrefix(directoryPath + "/") }
        stopPlayback(urls)
        let deletedIDs = Set(deleted.map(\.id))
        recordings.removeAll { deletedIDs.contains($0.id) }
        await Task.detached(priority: .utility) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }.value
        NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
    }

    nonisolated static func retentionCutoffDate(daysToKeep: Int, now: Date = Date()) -> Date? {
        guard daysToKeep > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -daysToKeep, to: now)
    }

    nonisolated static func isDeletableRecordingURL(_ url: URL) -> Bool {
        let recordingsPath = Recording.recordingsDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        return filePath.hasPrefix(recordingsPath + "/") && filePath != recordingsPath
    }

    private nonisolated static let pendingStatuses = [
        RecordingStatus.pending.rawValue,
        RecordingStatus.converting.rawValue,
        RecordingStatus.transcribing.rawValue
    ]

    nonisolated func recordingsOlderThan(days: Int) async throws -> (count: Int, oldestDate: Date?) {
        guard let cutoff = Self.retentionCutoffDate(daysToKeep: days) else { return (0, nil) }
        return try await dbQueue.read { db in
            let request = Recording
                .filter(Recording.Columns.timestamp < cutoff)
                .filter(!Self.pendingStatuses.contains(Recording.Columns.status))
            let count = try request.fetchCount(db)
            let oldest = try request
                .order(Recording.Columns.timestamp.asc)
                .limit(1)
                .fetchOne(db)
            return (count, oldest?.timestamp)
        }
    }

    func deleteRecordings(olderThanDays days: Int) async throws {
        guard let cutoff = Self.retentionCutoffDate(daysToKeep: days) else { return }
        let deleted = try await deleteRecordingsFromDB(olderThan: cutoff)
        await finishDeleting(deleted)
    }

    /// Recordings created through the indicator flow used to be saved with
    /// duration = 0. Restores real durations from the audio files on disk.
    nonisolated func backfillMissingDurations() async {
        let zeroDurationRecordings = (try? await dbQueue.read { db in
            try Recording
                .filter(Recording.Columns.duration <= 0)
                .filter(Recording.Columns.status == RecordingStatus.completed.rawValue)
                .fetchAll(db)
        }) ?? []
        guard !zeroDurationRecordings.isEmpty else { return }

        var updatedAny = false
        for recording in zeroDurationRecordings {
            guard FileManager.default.fileExists(atPath: recording.url.path) else { continue }
            let duration = await AudioUtil.audioDuration(url: recording.url)
            guard duration > 0 else { continue }
            do {
                try await dbQueue.write { db in
                    _ = try Recording
                        .filter(Recording.Columns.id == recording.id)
                        .updateAll(db, [Recording.Columns.duration.set(to: duration)])
                }
                updatedAny = true
            } catch {
                print("Failed to backfill a recording duration.")
            }
        }

        if updatedAny {
            await MainActor.run {
                NotificationCenter.default.post(name: Self.recordingsDidUpdateNotification, object: nil)
            }
        }
    }

    nonisolated static func recordingsDiskUsage() -> Int64 {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: Recording.recordingsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    private nonisolated static func literalSearchPattern(_ query: String) -> String {
        let escaped = query
            .replacingOccurrences(of: "!", with: "!!")
            .replacingOccurrences(of: "%", with: "!%")
            .replacingOccurrences(of: "_", with: "!_")
        return "%\(escaped)%"
    }

    func searchRecordings(query: String) -> [Recording] {
        do {
            return try dbQueue.read { db in
                try Recording
                    .filter(sql: "transcription LIKE ? ESCAPE '!'", arguments: [Self.literalSearchPattern(query)])
                    .order(Recording.Columns.timestamp.desc)
                    .limit(100)
                    .fetchAll(db)
            }
        } catch {
            print("Failed to search recordings.")
            return []
        }
    }
    
    nonisolated func searchRecordingsAsync(query: String, limit: Int = 100, offset: Int = 0) async throws -> [Recording] {
        try await dbQueue.read { db in
            try Recording
                .filter(sql: "transcription LIKE ? ESCAPE '!'", arguments: [Self.literalSearchPattern(query)])
                .order(Recording.Columns.timestamp.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }
}
