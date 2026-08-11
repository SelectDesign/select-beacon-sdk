import Foundation

/// Result of appending one detection to the durable pending queue.
struct EnqueueResult: Equatable, Sendable {
    let evictedCount: Int

    static let none = EnqueueResult(evictedCount: 0)
}

/// The on-disk representation of one finalized observation-window report.
///
/// Separate from live ranging models: includes a generated queue-record ID and
/// window aggregates so the upload coordinator can retry and acknowledge one
/// durable record. `id` is also the wire `idempotency_key` and must not change
/// across retries.
struct QueuedDetection: Codable, Equatable, Sendable {
    let id: UUID
    let uuid: UUID
    let major: Int
    let minor: Int
    let bestRSSI: Int
    let latestTimestamp: Date
    let windowStartedAt: Date
    let observationCount: Int
    let location: LocationFix?
    /// When the report was durably enqueued; used for the max-queue-age flush cap.
    let queuedAt: Date
    /// Retryable upload attempts completed for this record (persisted across launches).
    let uploadAttemptCount: Int

    init(report: FinalizedBeaconReport, queuedAt: Date) {
        self.init(
            id: UUID(),
            uuid: report.uuid,
            major: report.major,
            minor: report.minor,
            bestRSSI: report.bestRSSI,
            latestTimestamp: report.latestTimestamp,
            windowStartedAt: report.windowStartedAt,
            observationCount: report.observationCount,
            location: report.location,
            queuedAt: queuedAt,
            uploadAttemptCount: 0
        )
    }

    init(
        uuid: UUID,
        major: Int,
        minor: Int,
        bestRSSI: Int,
        latestTimestamp: Date,
        windowStartedAt: Date,
        observationCount: Int,
        location: LocationFix?,
        queuedAt: Date,
        uploadAttemptCount: Int = 0
    ) {
        self.init(
            id: UUID(),
            uuid: uuid,
            major: major,
            minor: minor,
            bestRSSI: bestRSSI,
            latestTimestamp: latestTimestamp,
            windowStartedAt: windowStartedAt,
            observationCount: observationCount,
            location: location,
            queuedAt: queuedAt,
            uploadAttemptCount: uploadAttemptCount
        )
    }

    init(
        id: UUID,
        uuid: UUID,
        major: Int,
        minor: Int,
        bestRSSI: Int,
        latestTimestamp: Date,
        windowStartedAt: Date,
        observationCount: Int,
        location: LocationFix?,
        queuedAt: Date,
        uploadAttemptCount: Int
    ) {
        self.id = id
        self.uuid = uuid
        self.major = major
        self.minor = minor
        self.bestRSSI = bestRSSI
        self.latestTimestamp = latestTimestamp
        self.windowStartedAt = windowStartedAt
        self.observationCount = observationCount
        self.location = location
        self.queuedAt = queuedAt
        self.uploadAttemptCount = uploadAttemptCount
    }

    func withUploadAttemptCount(_ count: Int) -> QueuedDetection {
        QueuedDetection(
            id: id,
            uuid: uuid,
            major: major,
            minor: minor,
            bestRSSI: bestRSSI,
            latestTimestamp: latestTimestamp,
            windowStartedAt: windowStartedAt,
            observationCount: observationCount,
            location: location,
            queuedAt: queuedAt,
            uploadAttemptCount: count
        )
    }

    /// Maps the private persistence record into the Select adapter's read-only
    /// snapshot model without exposing the queue's mutation operations.
    var pendingReport: SelectPendingBeaconReport {
        SelectPendingBeaconReport(
            id: id,
            uuid: uuid,
            major: major,
            minor: minor,
            bestRSSI: bestRSSI,
            latestTimestamp: latestTimestamp,
            windowStartedAt: windowStartedAt,
            observationCount: observationCount,
            location: location,
            queuedAt: queuedAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case major
        case minor
        case bestRSSI
        case rssi
        case latestTimestamp
        case detectedAt
        case windowStartedAt
        case observationCount
        case location
        case queuedAt
        case uploadAttemptCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        uuid = try container.decode(UUID.self, forKey: .uuid)
        major = try container.decode(Int.self, forKey: .major)
        minor = try container.decode(Int.self, forKey: .minor)
        if let bestRSSI = try container.decodeIfPresent(Int.self, forKey: .bestRSSI) {
            self.bestRSSI = bestRSSI
        } else {
            bestRSSI = try container.decode(Int.self, forKey: .rssi)
        }
        if let latestTimestamp = try container.decodeIfPresent(Date.self, forKey: .latestTimestamp) {
            self.latestTimestamp = latestTimestamp
        } else {
            latestTimestamp = try container.decode(Date.self, forKey: .detectedAt)
        }
        windowStartedAt = try container.decodeIfPresent(Date.self, forKey: .windowStartedAt)
            ?? latestTimestamp
        observationCount = try container.decodeIfPresent(Int.self, forKey: .observationCount) ?? 1
        location = try container.decodeIfPresent(LocationFix.self, forKey: .location)
        queuedAt = try container.decodeIfPresent(Date.self, forKey: .queuedAt) ?? latestTimestamp
        uploadAttemptCount = try container.decodeIfPresent(Int.self, forKey: .uploadAttemptCount) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(major, forKey: .major)
        try container.encode(minor, forKey: .minor)
        try container.encode(bestRSSI, forKey: .bestRSSI)
        try container.encode(latestTimestamp, forKey: .latestTimestamp)
        try container.encode(windowStartedAt, forKey: .windowStartedAt)
        try container.encode(observationCount, forKey: .observationCount)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encode(queuedAt, forKey: .queuedAt)
        try container.encode(uploadAttemptCount, forKey: .uploadAttemptCount)
    }
}

/// Result of reading the dead-letter store after applying retention bounds.
struct DeadLetterSnapshot: Equatable, Sendable {
    let records: [QueuedDetection]
    let evictedCount: Int
}

/// Storage boundary for reportable detections.
protocol DurableDetectionQueue: Sendable {
    func enqueue(_ detection: QueuedDetection, now: Date) async throws -> EnqueueResult
    func nextBatch(limit: Int) async throws -> [QueuedDetection]
    func pendingRecords() async throws -> [QueuedDetection]
    func acknowledge(ids: [UUID]) async throws
    /// Increments `uploadAttemptCount` by one for each matching pending id and persists.
    func recordUploadAttempts(for ids: [UUID]) async throws
    /// Moves matching pending records into the durable dead-letter store, then
    /// applies the same age/count retention bounds used for pending.
    func deadLetter(ids: [UUID], now: Date) async throws -> EnqueueResult
    /// Dead-lettered records retained for diagnostics (not uploaded). Applies
    /// age/count retention using `now` so oversized legacy files shrink on load.
    func deadLetteredRecords(now: Date) async throws -> DeadLetterSnapshot
    /// Empties the durable pending queue. Implementations must succeed even when the
    /// on-disk payload is corrupted so hosts can recover from unreadable state.
    func clear() async throws
    /// Empties the durable dead-letter store (diagnostics only; never re-uploaded).
    func clearDeadLetters() async throws
}

extension DurableDetectionQueue {
    func pendingRecords() async throws -> [QueuedDetection] {
        try await nextBatch(limit: .max)
    }

    func oldestQueuedAt() async throws -> Date? {
        try await nextBatch(limit: 1).first?.queuedAt
    }
}

enum DurableDetectionQueueError: Error, Equatable {
    case unreadableStoredDetections
}

protocol FileStoring: Sendable {
    func data(at url: URL) throws -> Data?
    func createDirectory(at url: URL) throws
    func writeAtomically(_ data: Data, to url: URL) throws
    /// Applies Data Protection to an existing file or directory (no-op if missing).
    func applyDataProtection(at url: URL) throws
}

struct DefaultFileStore: FileStoring {
    /// Class C — accessible after first unlock, including while locked later.
    /// Prefer this over `.complete` so background region wakes can still enqueue
    /// when the device is locked after the user has unlocked once since boot.
    static let durableFileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    func data(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: Self.durableFileProtection]
        )
        // Re-apply so directories created by an older SDK build also get Class C.
        try applyDataProtection(at: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        // `.completeFileProtectionUntilFirstUserAuthentication` (not `.completeFileProtection`):
        // background beacon wakes must be able to write while the device is locked,
        // after the user has unlocked once since boot. `.complete` would block those writes.
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func applyDataProtection(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes(
            [.protectionKey: Self.durableFileProtection],
            ofItemAtPath: url.path
        )
    }
}

/// Actor-isolated, persisted storage for detections awaiting upload.
actor FileDetectionQueue: DurableDetectionQueue {
    private let fileStore: FileStoring
    private let fileURL: URL
    private let deadLetterURL: URL
    private let maxQueueSize: Int
    private let maxRecordAge: TimeInterval
    private var records: [QueuedDetection] = []
    private var deadLetters: [QueuedDetection] = []
    private var hasLoaded = false
    private var hasLoadedDeadLetters = false

    init(
        storageIdentifier: String,
        fileStore: FileStoring = DefaultFileStore(),
        fileURL: URL? = nil,
        deadLetterURL: URL? = nil,
        maxQueueSize: Int = SDKConfiguration.default.maxQueueSize,
        maxRecordAge: TimeInterval = SDKConfiguration.default.maxRecordAge
    ) {
        self.fileStore = fileStore
        self.fileURL = fileURL ?? Self.defaultFileURL(
            storageIdentifier: storageIdentifier,
            fileNamePrefix: "pending-detections"
        )
        self.deadLetterURL = deadLetterURL ?? Self.defaultFileURL(
            storageIdentifier: storageIdentifier,
            fileNamePrefix: "dead-letter-detections"
        )
        self.maxQueueSize = max(1, maxQueueSize)
        self.maxRecordAge = max(0, maxRecordAge)
    }

    func enqueue(_ detection: QueuedDetection, now: Date) async throws -> EnqueueResult {
        try loadIfNeeded()
        let previousRecords = records
        var evicted = 0
        // Leave room for the new append (`>=` → at most maxQueueSize - 1 before append).
        evicted += pruneAgeAndCount(&records, now: now, maxCount: maxQueueSize - 1)

        records.append(detection)
        do {
            try persist()
        } catch {
            records = previousRecords
            throw error
        }
        return EnqueueResult(evictedCount: evicted)
    }

    func nextBatch(limit: Int) async throws -> [QueuedDetection] {
        try loadIfNeeded()
        return Array(records.prefix(Swift.max(0, limit)))
    }

    func acknowledge(ids: [UUID]) async throws {
        try loadIfNeeded()
        let previousRecords = records
        let acknowledged = Set(ids)
        records.removeAll { acknowledged.contains($0.id) }
        do {
            try persist()
        } catch {
            records = previousRecords
            throw error
        }
    }

    func recordUploadAttempts(for ids: [UUID]) async throws {
        try loadIfNeeded()
        let previousRecords = records
        let idSet = Set(ids)
        records = records.map { record in
            guard idSet.contains(record.id) else { return record }
            return record.withUploadAttemptCount(record.uploadAttemptCount + 1)
        }
        do {
            try persist()
        } catch {
            records = previousRecords
            throw error
        }
    }

    func deadLetter(ids: [UUID], now: Date) async throws -> EnqueueResult {
        try loadIfNeeded()
        try loadDeadLettersIfNeeded()
        let previousRecords = records
        let previousDeadLetters = deadLetters
        let idSet = Set(ids)
        let moving = records.filter { idSet.contains($0.id) }
        guard !moving.isEmpty else {
            let evicted = pruneDeadLetters(now: now)
            if evicted > 0 {
                do {
                    try persistDeadLetters()
                } catch {
                    deadLetters = previousDeadLetters
                    throw error
                }
            }
            return EnqueueResult(evictedCount: evicted)
        }
        records.removeAll { idSet.contains($0.id) }
        deadLetters.append(contentsOf: moving)
        let evicted = pruneDeadLetters(now: now)
        do {
            try persist()
            try persistDeadLetters()
        } catch {
            records = previousRecords
            deadLetters = previousDeadLetters
            throw error
        }
        return EnqueueResult(evictedCount: evicted)
    }

    func deadLetteredRecords(now: Date) async throws -> DeadLetterSnapshot {
        try loadDeadLettersIfNeeded()
        let previousDeadLetters = deadLetters
        let evicted = pruneDeadLetters(now: now)
        if evicted > 0 {
            do {
                try persistDeadLetters()
            } catch {
                deadLetters = previousDeadLetters
                throw error
            }
        }
        return DeadLetterSnapshot(records: deadLetters, evictedCount: evicted)
    }

    func clear() async throws {
        let previousRecords = records
        let previouslyLoaded = hasLoaded
        records = []
        hasLoaded = true
        do {
            try persist()
        } catch {
            records = previousRecords
            hasLoaded = previouslyLoaded
            throw error
        }
    }

    func clearDeadLetters() async throws {
        let previousDeadLetters = deadLetters
        let previouslyLoaded = hasLoadedDeadLetters
        deadLetters = []
        hasLoadedDeadLetters = true
        do {
            try persistDeadLetters()
        } catch {
            deadLetters = previousDeadLetters
            hasLoadedDeadLetters = previouslyLoaded
            throw error
        }
    }

    /// Drops aged and overflow records in place; returns how many were removed.
    ///
    /// `maxCount` is the inclusive maximum length after pruning (`while count > maxCount`).
    private func pruneAgeAndCount(
        _ records: inout [QueuedDetection],
        now: Date,
        maxCount: Int
    ) -> Int {
        var evicted = 0
        let cutoff = now.addingTimeInterval(-maxRecordAge)
        let beforeAge = records.count
        records.removeAll { $0.queuedAt < cutoff }
        evicted += beforeAge - records.count

        let boundedMax = max(0, maxCount)
        while records.count > boundedMax {
            records.removeFirst()
            evicted += 1
        }
        return evicted
    }

    /// Drops aged and overflow dead-letter records in place; returns how many were removed.
    private func pruneDeadLetters(now: Date) -> Int {
        pruneAgeAndCount(&deadLetters, now: now, maxCount: maxQueueSize)
    }

    private func loadIfNeeded() throws {
        guard !hasLoaded else { return }
        try ensureProtectedStorage(for: fileURL)
        guard let data = try fileStore.data(at: fileURL) else {
            hasLoaded = true
            return
        }

        do {
            records = try JSONDecoder().decode([QueuedDetection].self, from: data)
            hasLoaded = true
        } catch {
            throw DurableDetectionQueueError.unreadableStoredDetections
        }
    }

    private func loadDeadLettersIfNeeded() throws {
        guard !hasLoadedDeadLetters else { return }
        try ensureProtectedStorage(for: deadLetterURL)
        guard let data = try fileStore.data(at: deadLetterURL) else {
            hasLoadedDeadLetters = true
            return
        }
        do {
            deadLetters = try JSONDecoder().decode([QueuedDetection].self, from: data)
            hasLoadedDeadLetters = true
        } catch {
            throw DurableDetectionQueueError.unreadableStoredDetections
        }
    }

    private func persist() throws {
        try ensureProtectedStorage(for: fileURL)
        let data = try JSONEncoder().encode(records)
        try fileStore.writeAtomically(data, to: fileURL)
    }

    private func persistDeadLetters() throws {
        try ensureProtectedStorage(for: deadLetterURL)
        let data = try JSONEncoder().encode(deadLetters)
        try fileStore.writeAtomically(data, to: deadLetterURL)
    }

    /// Ensures the parent directory and any existing file use Class C Data Protection
    /// so legacy installs migrate and new files inherit the directory class.
    private func ensureProtectedStorage(for fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileStore.createDirectory(at: directoryURL)
        try fileStore.applyDataProtection(at: fileURL)
    }

    private static func defaultFileURL(storageIdentifier: String, fileNamePrefix: String) -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("SelectBeaconSDK", isDirectory: true)
            .appendingPathComponent("\(fileNamePrefix)-\(storageIdentifier).json")
    }
}
