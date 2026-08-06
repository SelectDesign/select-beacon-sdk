import XCTest
import CoreLocation
@_spi(SelectApp) @testable import SelectBeaconSDK

final class FileDetectionQueueTests: XCTestCase {
    private func testURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Invalid test URL: \(string)")
            return URL(fileURLWithPath: "/invalid-test-url")
        }
        return url
    }

    final class FailingFileStore: FileStoring, @unchecked Sendable {
        struct WriteError: Error {}

        func data(at url: URL) throws -> Data? {
            nil
        }

        func createDirectory(at url: URL) throws {}

        func writeAtomically(_ data: Data, to url: URL) throws {
            throw WriteError()
        }

        func applyDataProtection(at url: URL) throws {}
    }

    final class FailsAfterFirstWriteFileStore: FileStoring, @unchecked Sendable {
        struct WriteError: Error {}

        private var files: [URL: Data] = [:]
        private var writeCount = 0

        func data(at url: URL) throws -> Data? {
            files[url]
        }

        func createDirectory(at url: URL) throws {}

        func writeAtomically(_ data: Data, to url: URL) throws {
            writeCount += 1
            guard writeCount == 1 else {
                throw WriteError()
            }
            files[url] = data
        }

        func applyDataProtection(at url: URL) throws {}
    }

    func testQueueSurvivesReloadAndAcknowledgesInOrder() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/pending.json")
        let first = QueuedDetectionFixtures.make(
            latestTimestamp: Date(timeIntervalSince1970: 1_000),
            queuedAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = QueuedDetectionFixtures.make(
            latestTimestamp: Date(timeIntervalSince1970: 2_000),
            queuedAt: Date(timeIntervalSince1970: 2_000)
        )

        let firstQueue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        try await firstQueue.enqueue(first, now: Date(timeIntervalSince1970: 3_000))
        try await firstQueue.enqueue(second, now: Date(timeIntervalSince1970: 3_000))

        let reloadedQueue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        let firstBatch = try await reloadedQueue.nextBatch(limit: 1)
        XCTAssertEqual(firstBatch, [first])

        try await reloadedQueue.acknowledge(ids: [first.id])
        let remainingBatch = try await reloadedQueue.nextBatch(limit: 10)
        XCTAssertEqual(remainingBatch, [second])
    }

    func testQueuePropagatesPersistenceFailure() async throws {
        let queue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: FailingFileStore(),
            fileURL: URL(fileURLWithPath: "/queue/pending.json")
        )
        let detection = QueuedDetectionFixtures.make()

        do {
            try await queue.enqueue(detection, now: Date(timeIntervalSince1970: 1_000_000))
            XCTFail("Expected queue persistence to fail")
        } catch {
            XCTAssertTrue(true)
        }

        let records = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(records, [])
    }

    func testFailedAcknowledgementRetainsRecordInMemory() async throws {
        let fileURL = URL(fileURLWithPath: "/queue/pending.json")
        let queue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: FailsAfterFirstWriteFileStore(),
            fileURL: fileURL
        )
        let detection = QueuedDetectionFixtures.make()
        try await queue.enqueue(detection, now: Date(timeIntervalSince1970: 1_000_000))

        do {
            try await queue.acknowledge(ids: [detection.id])
            XCTFail("Expected acknowledgement persistence to fail")
        } catch {
            XCTAssertTrue(true)
        }

        let retained = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(retained, [detection])
    }

    func testMalformedStoredQueueIsNotOverwritten() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/pending.json")
        let malformedData = Data("{not-json".utf8)
        fileStore.seed(malformedData, at: fileURL)
        let queue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        let detection = QueuedDetectionFixtures.make()

        do {
            _ = try await queue.nextBatch(limit: 10)
            XCTFail("Expected malformed stored queue to fail")
        } catch let error as DurableDetectionQueueError {
            XCTAssertEqual(error, .unreadableStoredDetections)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await queue.enqueue(detection, now: Date(timeIntervalSince1970: 1_000_000))
            XCTFail("Expected malformed stored queue to fail")
        } catch let error as DurableDetectionQueueError {
            XCTAssertEqual(error, .unreadableStoredDetections)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(fileStore.files[fileURL], malformedData)
    }

    func testLegacyQueueJSONMigratesWithoutLocation() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/pending.json")
        let uuid = SDKConfiguration.default.monitoredUUIDs[0]
        let recordID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let detectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacyPayload = try JSONEncoder().encode([
            LegacyQueuedDetection(
                id: recordID,
                uuid: uuid,
                major: 1,
                minor: 42,
                rssi: -55,
                detectedAt: detectedAt
            ),
        ])
        fileStore.seed(legacyPayload, at: fileURL)

        let queue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        let batch = try await queue.nextBatch(limit: 10)

        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch[0].id, recordID)
        XCTAssertEqual(batch[0].bestRSSI, -55)
        XCTAssertEqual(batch[0].latestTimestamp, detectedAt)
        XCTAssertEqual(batch[0].observationCount, 1)
        XCTAssertNil(batch[0].location)
        XCTAssertEqual(batch[0].queuedAt, detectedAt)
    }

    func testQueuePersistsLocationRoundTrip() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/pending.json")
        let location = LocationFix(
            latitude: 37.77,
            longitude: -122.42,
            horizontalAccuracy: 80,
            timestamp: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let detection = QueuedDetectionFixtures.make(
            bestRSSI: -48,
            latestTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
            location: location
        )

        let firstQueue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        try await firstQueue.enqueue(detection, now: Date(timeIntervalSince1970: 1_000_000))

        let reloaded = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        let batch = try await reloaded.nextBatch(limit: 10)
        XCTAssertEqual(batch, [detection])
        XCTAssertEqual(batch.first?.location, location)
    }

    func testQueueStorageIdentifiersSeparateCustomersAndEndpoints() async throws {
        guard let identity = AppIdentity(appKey: "customer", appSecret: "test-secret"),
              let production = SDKEnablementConfiguration(
                  identity: identity,
                  environment: .production
              ),
              let staging = SDKEnablementConfiguration(
                  identity: identity,
                  environment: .staging(
                      baseURL: testURL("https://staging.example.com")
                  )
              ) else {
            return XCTFail("Test configuration should be valid")
        }

        XCTAssertNotEqual(production.queueStorageIdentifier, staging.queueStorageIdentifier)

        let fileStore = MemoryFileStore()
        let productionQueue = FileDetectionQueue(
            storageIdentifier: production.queueStorageIdentifier,
            fileStore: fileStore,
            fileURL: URL(fileURLWithPath: "/queue/\(production.queueStorageIdentifier).json")
        )
        let stagingQueue = FileDetectionQueue(
            storageIdentifier: staging.queueStorageIdentifier,
            fileStore: fileStore,
            fileURL: URL(fileURLWithPath: "/queue/\(staging.queueStorageIdentifier).json")
        )

        try await productionQueue.enqueue(QueuedDetectionFixtures.make(), now: Date(timeIntervalSince1970: 1_000_000))

        let productionBatch = try await productionQueue.nextBatch(limit: 10)
        let stagingBatch = try await stagingQueue.nextBatch(limit: 10)
        XCTAssertEqual(productionBatch.count, 1)
        XCTAssertTrue(stagingBatch.isEmpty)
    }

    func testClearEmptiesQueueAndPersistsAcrossReload() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/pending.json")
        let queue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        try await queue.enqueue(QueuedDetectionFixtures.make(), now: Date(timeIntervalSince1970: 1_000_000))
        try await queue.clear()

        let emptied = try await queue.nextBatch(limit: 10)
        XCTAssertTrue(emptied.isEmpty)

        let reloaded = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        let reloadedBatch = try await reloaded.nextBatch(limit: 10)
        XCTAssertTrue(reloadedBatch.isEmpty)
    }

    func testClearOverwritesMalformedStoredQueue() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/pending.json")
        fileStore.seed(Data("{not-json".utf8), at: fileURL)
        let queue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )

        try await queue.clear()

        let emptied = try await queue.nextBatch(limit: 10)
        XCTAssertTrue(emptied.isEmpty)
        let reloaded = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        let reloadedBatch = try await reloaded.nextBatch(limit: 10)
        XCTAssertTrue(reloadedBatch.isEmpty)
    }

    func testEnqueueBeyondMaxQueueSizeEvictsOldest() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/bounded.json")
        let queue = FileDetectionQueue(
            storageIdentifier: "bounded",
            fileStore: fileStore,
            fileURL: fileURL,
            maxQueueSize: 2,
            maxRecordAge: 604_800
        )
        let first = QueuedDetectionFixtures.make(minor: 1, queuedAt: Date(timeIntervalSince1970: 1))
        let second = QueuedDetectionFixtures.make(minor: 2, queuedAt: Date(timeIntervalSince1970: 2))
        let third = QueuedDetectionFixtures.make(minor: 3, queuedAt: Date(timeIntervalSince1970: 3))
        let now = Date(timeIntervalSince1970: 10)

        let firstResult = try await queue.enqueue(first, now: now)
        let secondResult = try await queue.enqueue(second, now: now)
        XCTAssertEqual(firstResult.evictedCount, 0)
        XCTAssertEqual(secondResult.evictedCount, 0)
        let result = try await queue.enqueue(third, now: now)
        XCTAssertEqual(result.evictedCount, 1)

        let batch = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(batch.map(\.minor), [2, 3])
    }

    func testEnqueueDropsRecordsOlderThanMaxRecordAge() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/aged.json")
        let queue = FileDetectionQueue(
            storageIdentifier: "aged",
            fileStore: fileStore,
            fileURL: fileURL,
            maxQueueSize: 50,
            maxRecordAge: 100
        )
        let old = QueuedDetectionFixtures.make(minor: 1, queuedAt: Date(timeIntervalSince1970: 1))
        let recent = QueuedDetectionFixtures.make(minor: 2, queuedAt: Date(timeIntervalSince1970: 150))
        _ = try await queue.enqueue(old, now: Date(timeIntervalSince1970: 50))
        let result = try await queue.enqueue(recent, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(result.evictedCount, 1)
        let batch = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(batch.map(\.minor), [2])
    }

    func testQueueNeverExceedsMaxSizeAcrossManyEnqueues() async throws {
        let fileStore = MemoryFileStore()
        let queue = FileDetectionQueue(
            storageIdentifier: "cap",
            fileStore: fileStore,
            fileURL: URL(fileURLWithPath: "/queue/cap.json"),
            maxQueueSize: 3,
            maxRecordAge: 604_800
        )
        let now = Date(timeIntervalSince1970: 1_000)
        for minor in 1...20 {
            _ = try await queue.enqueue(
                QueuedDetectionFixtures.make(minor: minor, queuedAt: now),
                now: now
            )
            let count = try await queue.nextBatch(limit: 100).count
            XCTAssertLessThanOrEqual(count, 3)
        }
        let final = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(final.map(\.minor), [18, 19, 20])
    }

    func testDeadLetterRetainsMovedRecords() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/pending-dl.json")
        let deadLetterURL = URL(fileURLWithPath: "/queue/dead-dl.json")
        let queue = FileDetectionQueue(
            storageIdentifier: "dl",
            fileStore: fileStore,
            fileURL: fileURL,
            deadLetterURL: deadLetterURL
        )
        let detection = QueuedDetectionFixtures.make(minor: 9)
        _ = try await queue.enqueue(detection, now: Date(timeIntervalSince1970: 1))
        try await queue.deadLetter(ids: [detection.id])
        let pending = try await queue.nextBatch(limit: 10)
        XCTAssertTrue(pending.isEmpty)
        let dead = try await queue.deadLetteredRecords()
        XCTAssertEqual(dead.map(\.minor), [9])
    }

    func testEnqueueAppliesCompleteUntilFirstUserAuthenticationToFilesAndDirectory() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/protected/pending.json")
        let deadLetterURL = URL(fileURLWithPath: "/protected/dead.json")
        let directoryURL = fileURL.deletingLastPathComponent()
        let queue = FileDetectionQueue(
            storageIdentifier: "protected",
            fileStore: fileStore,
            fileURL: fileURL,
            deadLetterURL: deadLetterURL
        )

        _ = try await queue.enqueue(
            QueuedDetectionFixtures.make(minor: 1),
            now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            fileStore.protectionByURL[directoryURL],
            FileProtectionType.completeUntilFirstUserAuthentication
        )
        XCTAssertEqual(
            fileStore.protectionByURL[fileURL],
            FileProtectionType.completeUntilFirstUserAuthentication
        )
        XCTAssertNotEqual(fileStore.protectionByURL[fileURL], .complete)
        XCTAssertNotEqual(fileStore.protectionByURL[fileURL], .none)
    }

    func testDeadLetterWriteAppliesProtectionToDeadLetterFile() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/protected/pending-dl2.json")
        let deadLetterURL = URL(fileURLWithPath: "/protected/dead-dl2.json")
        let queue = FileDetectionQueue(
            storageIdentifier: "protected-dl",
            fileStore: fileStore,
            fileURL: fileURL,
            deadLetterURL: deadLetterURL
        )
        let detection = QueuedDetectionFixtures.make(minor: 3)
        _ = try await queue.enqueue(detection, now: Date(timeIntervalSince1970: 1))
        try await queue.deadLetter(ids: [detection.id])

        XCTAssertEqual(
            fileStore.protectionByURL[deadLetterURL],
            FileProtectionType.completeUntilFirstUserAuthentication
        )
        XCTAssertEqual(
            fileStore.protectionByURL[deadLetterURL.deletingLastPathComponent()],
            FileProtectionType.completeUntilFirstUserAuthentication
        )
    }

    func testLoadMigratesUnprotectedExistingFiles() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/migrate/pending.json")
        let deadLetterURL = URL(fileURLWithPath: "/migrate/dead.json")
        let detection = QueuedDetectionFixtures.make(minor: 5)
        let encoded = try JSONEncoder().encode([detection])
        fileStore.seed(encoded, at: fileURL)
        XCTAssertNil(fileStore.protectionByURL[fileURL])

        let queue = FileDetectionQueue(
            storageIdentifier: "migrate",
            fileStore: fileStore,
            fileURL: fileURL,
            deadLetterURL: deadLetterURL
        )
        let loaded = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(loaded.map(\.minor), [5])
        XCTAssertEqual(
            fileStore.protectionByURL[fileURL],
            FileProtectionType.completeUntilFirstUserAuthentication
        )
        XCTAssertEqual(
            fileStore.protectionByURL[fileURL.deletingLastPathComponent()],
            FileProtectionType.completeUntilFirstUserAuthentication
        )
    }

    func testDefaultFileStoreWritesProtectedFilesOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectBeaconSDK-DataProtection-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("pending.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DefaultFileStore()
        try store.createDirectory(at: root)
        try store.writeAtomically(Data(#"[]"#.utf8), to: fileURL)

        XCTAssertTrue(try isCompleteUntilFirstUserAuthentication(at: fileURL))
        // Directory protection is applied via createDirectory attributes + setAttributes.
        // Some simulator volumes omit a readable protection key for directories; assert
        // when the platform surfaces one.
        if let directoryProtection = try fileProtectionRawValue(at: root) {
            XCTAssertTrue(directoryProtection.contains("CompleteUntilFirstUserAuthentication"))
        }
        XCTAssertFalse(try isCompleteProtection(at: fileURL))
        XCTAssertFalse(try isNoProtection(at: fileURL))

        // Migration path: strip protection then re-apply.
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: fileURL.path
        )
        try store.applyDataProtection(at: fileURL)
        XCTAssertTrue(try isCompleteUntilFirstUserAuthentication(at: fileURL))
    }

    private func isCompleteUntilFirstUserAuthentication(at url: URL) throws -> Bool {
        let raw = try fileProtectionRawValue(at: url) ?? ""
        return raw.contains("CompleteUntilFirstUserAuthentication")
    }

    private func isCompleteProtection(at url: URL) throws -> Bool {
        let raw = try fileProtectionRawValue(at: url) ?? ""
        return raw.hasSuffix("Complete") || raw.hasSuffix("FileProtectionComplete")
    }

    private func isNoProtection(at url: URL) throws -> Bool {
        let raw = try fileProtectionRawValue(at: url) ?? ""
        return raw.contains("None") || raw.contains("NoProtection")
    }

    /// Simulator may report `NSFileProtection*` or `NSURLFileProtection*` raw strings.
    private func fileProtectionRawValue(at url: URL) throws -> String? {
        let values = try url.resourceValues(forKeys: [.fileProtectionKey])
        if let raw = values.fileProtection?.rawValue {
            return raw
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let protection = attrs[.protectionKey] as? FileProtectionType {
            return protection.rawValue
        }
        return attrs[.protectionKey] as? String
    }
}

private struct LegacyQueuedDetection: Encodable {
    let id: UUID
    let uuid: UUID
    let major: Int
    let minor: Int
    let rssi: Int
    let detectedAt: Date
}

