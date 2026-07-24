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
    }

    func testQueueSurvivesReloadAndAcknowledgesInOrder() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/pending.json")
        let beacon = DetectedBeacon(
            uuid: SDKConfiguration.default.monitoredUUIDs[0],
            major: 1,
            minor: 42,
            rssi: -55
        )
        let first = QueuedDetection(detection: beacon, detectedAt: .distantPast)
        let second = QueuedDetection(detection: beacon, detectedAt: .now)

        let firstQueue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        try await firstQueue.enqueue(first)
        try await firstQueue.enqueue(second)

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
        let detection = QueuedDetection(
            detection: DetectedBeacon(
                uuid: SDKConfiguration.default.monitoredUUIDs[0],
                major: 1,
                minor: 42,
                rssi: -55
            ),
            detectedAt: .now
        )

        do {
            try await queue.enqueue(detection)
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
        let detection = QueuedDetection(
            detection: DetectedBeacon(
                uuid: SDKConfiguration.default.monitoredUUIDs[0],
                major: 1,
                minor: 42,
                rssi: -55
            ),
            detectedAt: .now
        )
        try await queue.enqueue(detection)

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
        let detection = QueuedDetection(
            detection: DetectedBeacon(
                uuid: SDKConfiguration.default.monitoredUUIDs[0],
                major: 1,
                minor: 42,
                rssi: -55
            ),
            detectedAt: .now
        )

        do {
            _ = try await queue.nextBatch(limit: 10)
            XCTFail("Expected malformed stored queue to fail")
        } catch let error as DurableDetectionQueueError {
            XCTAssertEqual(error, .unreadableStoredDetections)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await queue.enqueue(detection)
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
        let detection = QueuedDetection(
            detection: DetectedBeacon(
                uuid: SDKConfiguration.default.monitoredUUIDs[0],
                major: 1,
                minor: 42,
                rssi: -48
            ),
            detectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            location: location
        )

        let firstQueue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        try await firstQueue.enqueue(detection)

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
        guard let identity = AppIdentity(appKey: "customer"),
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
        let beacon = DetectedBeacon(
            uuid: SDKConfiguration.default.monitoredUUIDs[0],
            major: 1,
            minor: 42,
            rssi: -55
        )
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

        try await productionQueue.enqueue(QueuedDetection(detection: beacon, detectedAt: .now))

        let productionBatch = try await productionQueue.nextBatch(limit: 10)
        let stagingBatch = try await stagingQueue.nextBatch(limit: 10)
        XCTAssertEqual(productionBatch.count, 1)
        XCTAssertTrue(stagingBatch.isEmpty)
    }

    func testClearEmptiesQueueAndPersistsAcrossReload() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/pending.json")
        let beacon = DetectedBeacon(
            uuid: SDKConfiguration.default.monitoredUUIDs[0],
            major: 1,
            minor: 42,
            rssi: -55
        )
        let queue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        try await queue.enqueue(QueuedDetection(detection: beacon, detectedAt: .now))
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
}

private struct LegacyQueuedDetection: Encodable {
    let id: UUID
    let uuid: UUID
    let major: Int
    let minor: Int
    let rssi: Int
    let detectedAt: Date
}

