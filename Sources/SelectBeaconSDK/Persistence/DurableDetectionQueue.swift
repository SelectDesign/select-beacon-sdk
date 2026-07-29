import Foundation

/// The on-disk representation of one finalized observation-window report.
///
/// Separate from live ranging models: includes a generated queue-record ID and
/// window aggregates so the upload coordinator can retry and acknowledge one
/// durable record.
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

    init(report: FinalizedBeaconReport, queuedAt: Date) {
        id = UUID()
        uuid = report.uuid
        major = report.major
        minor = report.minor
        bestRSSI = report.bestRSSI
        latestTimestamp = report.latestTimestamp
        windowStartedAt = report.windowStartedAt
        observationCount = report.observationCount
        location = report.location
        self.queuedAt = queuedAt
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
        queuedAt: Date
    ) {
        id = UUID()
        self.uuid = uuid
        self.major = major
        self.minor = minor
        self.bestRSSI = bestRSSI
        self.latestTimestamp = latestTimestamp
        self.windowStartedAt = windowStartedAt
        self.observationCount = observationCount
        self.location = location
        self.queuedAt = queuedAt
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
    }
}

/// Storage boundary for reportable detections.
///
/// `async` marks a potential actor or disk-I/O boundary. Swift callers must use
/// `await`, which makes the suspension point explicit; code running on the main
/// actor can continue processing other events while the queue works.
protocol DurableDetectionQueue: Sendable {
    func enqueue(_ detection: QueuedDetection) async throws
    func nextBatch(limit: Int) async throws -> [QueuedDetection]
    func pendingRecords() async throws -> [QueuedDetection]
    func acknowledge(ids: [UUID]) async throws
    /// Empties the durable queue. Implementations must succeed even when the
    /// on-disk payload is corrupted so hosts can recover from unreadable state.
    func clear() async throws
}

extension DurableDetectionQueue {
    /// Default full FIFO inspection used by the Select-app adapter. Upload code
    /// can override this later with an explicit batch-selection policy.
    func pendingRecords() async throws -> [QueuedDetection] {
        try await nextBatch(limit: .max)
    }

    /// FIFO head enqueue time, used to schedule the max-queue-age flush cap.
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
}

struct DefaultFileStore: FileStoring {
    func data(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

/// Actor-isolated, persisted storage for detections awaiting upload.
///
/// An actor is Swift's serialized mutable-state container. Unlike a lock, its
/// methods suspend at `await` points rather than blocking the main thread.
actor FileDetectionQueue: DurableDetectionQueue {
    private let fileStore: FileStoring
    private let fileURL: URL
    private var records: [QueuedDetection] = []
    private var hasLoaded = false

    init(
        storageIdentifier: String,
        fileStore: FileStoring = DefaultFileStore(),
        fileURL: URL? = nil
    ) {
        self.fileStore = fileStore
        self.fileURL = fileURL ?? Self.defaultFileURL(storageIdentifier: storageIdentifier)
    }

    func enqueue(_ detection: QueuedDetection) async throws {
        // Load before appending so a process restart preserves FIFO order rather
        // than replacing the existing persisted queue.
        try loadIfNeeded()
        let previousRecords = records
        records.append(detection)
        do {
            try persist()
        } catch {
            // A queue record is considered pending only after the atomic file
            // replacement succeeds. Restore actor memory so a later snapshot
            // cannot expose a record that would disappear on process restart.
            records = previousRecords
            throw error
        }
    }

    func nextBatch(limit: Int) async throws -> [QueuedDetection] {
        // Non-destructive peek. Records leave the queue only through `acknowledge`
        // after the upload transport reports HTTP 200 for the batch.
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
            // Keep memory aligned with the still-existing file. A future
            // uploader may retry acknowledgement without losing this record.
            records = previousRecords
            throw error
        }
    }

    func clear() async throws {
        // Bypass `loadIfNeeded` so a corrupted payload can still be overwritten
        // with an empty durable queue and the host can recover.
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

    private func loadIfNeeded() throws {
        guard !hasLoaded else { return }
        guard let data = try fileStore.data(at: fileURL) else {
            hasLoaded = true
            return
        }

        do {
            records = try JSONDecoder().decode([QueuedDetection].self, from: data)
            hasLoaded = true
        } catch {
            // Do not set `hasLoaded` or overwrite the file. Retrying preserves
            // the original bytes for diagnosis instead of silently losing data.
            throw DurableDetectionQueueError.unreadableStoredDetections
        }
    }

    private func persist() throws {
        // Atomic replacement avoids leaving a partially written JSON file if
        // the process is interrupted during a write.
        try fileStore.createDirectory(at: fileURL.deletingLastPathComponent())
        let data = try JSONEncoder().encode(records)
        try fileStore.writeAtomically(data, to: fileURL)
    }

    private static func defaultFileURL(storageIdentifier: String) -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("SelectBeaconSDK", isDirectory: true)
            .appendingPathComponent("pending-detections-\(storageIdentifier).json")
    }
}
