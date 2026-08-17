import XCTest
import CoreLocation
@testable import SelectBeaconAppSupport
@_spi(SelectApp) @testable import SelectBeaconSDK
@testable import SelectBeaconSDKTestSupport

@MainActor
final class SelectBeaconAppSupportTests: XCTestCase {
    private func waitForQueueRecord(
        _ queue: InMemoryQueue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while queue.records.isEmpty,
              DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if queue.records.isEmpty {
            XCTFail("Timed out waiting for a queued report", file: file, line: line)
        }
    }

    func testAdapterPublishesActiveAndPendingSnapshots() async throws {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver() },
            lifecycleObserver: { FakeLifecycleObserver() },
            clock: clock,
            queue: { _ in queue },
            networkPathObserver: { FakeNetworkPathObserver() },
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "select-app", appSecret: "test-secret")
        )
        let adapter = SelectBeaconAppSupport(sdk: sdk)
        let openWindowsUpdate = expectation(description: "Open windows update")
        openWindowsUpdate.assertForOverFulfill = false
        let pendingUpdate = expectation(description: "Pending report update")
        adapter.onOpenWindowsChanged = { windows in
            if windows.contains(where: { $0.minor == 42 }) {
                openWindowsUpdate.fulfill()
            }
        }
        adapter.onPendingReportsChanged = { reports in
            XCTAssertEqual(reports.map(\.minor), [42])
            XCTAssertEqual(reports.first?.observationCount, 1)
            XCTAssertEqual(reports.first?.bestRSSI, -55)
            XCTAssertNotNil(reports.first?.queuedAt)
            pendingUpdate.fulfill()
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(
                uuid: SDKConfiguration.default.monitoredUUIDs[0],
                major: 1,
                minor: 42,
                rssi: -55
            ),
        ])

        await fulfillment(of: [openWindowsUpdate], timeout: 1)
        XCTAssertEqual(adapter.currentOpenWindows.map(\.minor), [42])

        clock.now = clock.now.addingTimeInterval(SDKConfiguration.default.absenceTimeout + 0.1)
        absenceScheduler.fire()

        await fulfillment(of: [pendingUpdate], timeout: 1)

        XCTAssertEqual(adapter.currentBeacons.map(\.minor), [42])
        XCTAssertTrue(adapter.currentOpenWindows.isEmpty)
        let pendingReports = try await adapter.pendingReports()
        XCTAssertEqual(pendingReports.map(\.minor), [42])
        XCTAssertNil(pendingReports.first?.location)
    }

    func testPendingReportsRefreshAfterDebugAutoAckUpload() async throws {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let lifecycle = FakeLifecycleObserver()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver() },
            lifecycleObserver: { lifecycle },
            clock: clock,
            queue: { _ in queue },
            networkPathObserver: { FakeNetworkPathObserver() },
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "select-app", appSecret: "test-secret")
        )
        sdk.selectInstallDebugAutoAckUploadSeams()
        let adapter = SelectBeaconAppSupport(sdk: sdk)

        var sawQueued = false
        let queued = expectation(description: "Queue publishes durable report")
        let emptied = expectation(description: "Queue emptied after ack")
        adapter.onPendingReportsChanged = { reports in
            if reports.map(\.minor) == [42], !sawQueued {
                sawQueued = true
                queued.fulfill()
            }
            if reports.isEmpty, sawQueued {
                emptied.fulfill()
            }
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(
                uuid: SDKConfiguration.default.monitoredUUIDs[0],
                major: 1,
                minor: 42,
                rssi: -55
            ),
        ])
        clock.now = clock.now.addingTimeInterval(SDKConfiguration.default.absenceTimeout + 0.1)
        absenceScheduler.fire()

        await fulfillment(of: [queued], timeout: 1)
        lifecycle.setActive(false)

        await fulfillment(of: [emptied], timeout: 2)
        let remaining = try await adapter.pendingReports()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAdapterForwardsStopFinalizePendingAcrossOpenWindowGap() async throws {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver() },
            lifecycleObserver: { FakeLifecycleObserver() },
            clock: MutableClock(now: Date(timeIntervalSince1970: 1_000_000)),
            queue: { _ in queue },
            networkPathObserver: { FakeNetworkPathObserver() },
            identity: AppIdentity(appKey: "select-app", appSecret: "test-secret")
        )
        let adapter = SelectBeaconAppSupport(sdk: sdk)
        XCTAssertFalse(adapter.isStopFinalizePending)

        var pendingValues: [Bool] = []
        let becamePending = expectation(description: "Adapter pending true")
        let cleared = expectation(description: "Adapter pending false")
        adapter.onStopFinalizePendingChanged = { pending in
            pendingValues.append(pending)
            if pending {
                becamePending.fulfill()
            } else {
                cleared.fulfill()
            }
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(
                uuid: SDKConfiguration.default.monitoredUUIDs[0],
                major: 1,
                minor: 42,
                rssi: -55
            ),
        ])
        XCTAssertEqual(adapter.currentOpenWindows.map(\.minor), [42])

        sdk.stop()

        XCTAssertTrue(adapter.currentOpenWindows.isEmpty)
        XCTAssertTrue(adapter.isStopFinalizePending)
        await fulfillment(of: [becamePending], timeout: 1)
        await queue.waitForWriteStart()

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [cleared], timeout: 1)

        XCTAssertFalse(adapter.isStopFinalizePending)
        XCTAssertEqual(pendingValues, [true, false])
        let pendingReports = try await adapter.pendingReports()
        XCTAssertEqual(pendingReports.map(\.minor), [42])
    }

    func testClearPendingReportsEmptiesAdapterSnapshot() async throws {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver() },
            lifecycleObserver: { FakeLifecycleObserver() },
            clock: clock,
            queue: { _ in queue },
            networkPathObserver: { FakeNetworkPathObserver() },
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "select-app", appSecret: "test-secret")
        )
        let adapter = SelectBeaconAppSupport(sdk: sdk)
        let emptied = expectation(description: "Adapter pending emptied")
        adapter.onPendingReportsChanged = { reports in
            if reports.isEmpty {
                emptied.fulfill()
            }
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(
                uuid: SDKConfiguration.default.monitoredUUIDs[0],
                major: 1,
                minor: 42,
                rssi: -55
            ),
        ])
        clock.now = clock.now.addingTimeInterval(SDKConfiguration.default.absenceTimeout + 0.1)
        absenceScheduler.fire()
        await waitForQueueRecord(queue)

        sdk.stop()
        try await adapter.clearPendingReports()
        await fulfillment(of: [emptied], timeout: 1)
        let pending = try await adapter.pendingReports()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testClearPendingReportsMapsDetectionActiveError() async throws {
        let sdk = SelectBeaconSDK(
            engine: { FakeEngine() },
            permissionObserver: { FakePermissionObserver() },
            lifecycleObserver: { FakeLifecycleObserver() },
            clock: MutableClock(now: Date(timeIntervalSince1970: 1_000_000)),
            queue: { _ in InMemoryQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            identity: AppIdentity(appKey: "select-app", appSecret: "test-secret")
        )
        let adapter = SelectBeaconAppSupport(sdk: sdk)
        sdk.start()

        do {
            try await adapter.clearPendingReports()
            XCTFail("Expected detectionActive")
        } catch let error as PendingReportsClearError {
            XCTAssertEqual(error, .detectionActive)
        }
    }

    func testClearPendingReportsMapsStopFinalizePendingError() async throws {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver() },
            lifecycleObserver: { FakeLifecycleObserver() },
            clock: MutableClock(now: Date(timeIntervalSince1970: 1_000_000)),
            queue: { _ in queue },
            networkPathObserver: { FakeNetworkPathObserver() },
            identity: AppIdentity(appKey: "select-app", appSecret: "test-secret")
        )
        let adapter = SelectBeaconAppSupport(sdk: sdk)

        sdk.start()
        engine.emit([
            DetectedBeacon(
                uuid: SDKConfiguration.default.monitoredUUIDs[0],
                major: 1,
                minor: 42,
                rssi: -55
            ),
        ])
        sdk.stop()
        await queue.waitForWriteStart()

        do {
            try await adapter.clearPendingReports()
            XCTFail("Expected stopFinalizePending")
        } catch let error as PendingReportsClearError {
            XCTAssertEqual(error, .stopFinalizePending)
        }

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
    }

    func testDeadLetteredReportsAppearAfterClientErrorFlush() async throws {
        final class PoisonTransport: UploadTransport {
            func upload(
                detections: [QueuedDetection],
                authorization: UploadAuthorization
            ) async throws -> UploadResponse {
                _ = detections
                _ = authorization
                throw HTTPIngestUploadError.clientError(statusCode: 400)
            }
        }

        struct FixedDeviceIdentifier: DeviceIdentifying {
            var deviceId: String? { "test-device-id" }
        }

        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let lifecycle = FakeLifecycleObserver()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver() },
            lifecycleObserver: { lifecycle },
            clock: clock,
            queue: { _ in queue },
            networkPathObserver: { FakeNetworkPathObserver() },
            deviceIdentifier: { FixedDeviceIdentifier() },
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "select-app", appSecret: "test-secret")
        )
        sdk.selectInstallUploadSeams(
            auth: DebugAutoAckAuthProvider(),
            transport: PoisonTransport()
        )
        let adapter = SelectBeaconAppSupport(sdk: sdk)

        var sawQueued = false
        let queued = expectation(description: "Pending publishes durable report")
        let pendingEmptied = expectation(description: "Pending emptied after dead-letter")
        let deadLetterPublished = expectation(description: "Dead letter publishes report")
        adapter.onPendingReportsChanged = { reports in
            if reports.map(\.minor) == [42], !sawQueued {
                sawQueued = true
                queued.fulfill()
            }
            if reports.isEmpty, sawQueued {
                pendingEmptied.fulfill()
            }
        }
        adapter.onDeadLetteredReportsChanged = { reports in
            if reports.map(\.minor) == [42] {
                deadLetterPublished.fulfill()
            }
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(
                uuid: SDKConfiguration.default.monitoredUUIDs[0],
                major: 1,
                minor: 42,
                rssi: -55
            ),
        ])
        clock.now = clock.now.addingTimeInterval(SDKConfiguration.default.absenceTimeout + 0.1)
        absenceScheduler.fire()

        await fulfillment(of: [queued], timeout: 1)
        lifecycle.setActive(false)

        await fulfillment(of: [pendingEmptied, deadLetterPublished], timeout: 2)
        let pending = try await adapter.pendingReports()
        let dead = try await adapter.deadLetteredReports()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(dead.map(\.minor), [42])
        XCTAssertEqual(queue.deadLetters.map(\.minor), [42])
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testClearPendingReportsLeavesDeadLetters() async throws {
        let queue = InMemoryQueue()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let sdk = SelectBeaconSDK(
            engine: { FakeEngine() },
            permissionObserver: { FakePermissionObserver() },
            lifecycleObserver: { FakeLifecycleObserver() },
            clock: clock,
            queue: { _ in queue },
            networkPathObserver: { FakeNetworkPathObserver() },
            identity: AppIdentity(appKey: "select-app", appSecret: "test-secret")
        )
        let adapter = SelectBeaconAppSupport(sdk: sdk)

        let detection = QueuedDetection(
            id: UUID(),
            uuid: SDKConfiguration.default.monitoredUUIDs[0],
            major: 1,
            minor: 7,
            bestRSSI: -50,
            latestTimestamp: clock.now,
            windowStartedAt: clock.now.addingTimeInterval(-60),
            observationCount: 3,
            location: nil,
            queuedAt: clock.now,
            uploadAttemptCount: 0
        )
        _ = try await queue.enqueue(detection, now: clock.now)
        _ = try await queue.deadLetter(ids: [detection.id], now: clock.now)

        let deadBeforeClear = try await adapter.deadLetteredReports()
        XCTAssertEqual(deadBeforeClear.map(\.minor), [7])
        try await adapter.clearPendingReports()
        let pendingAfterClear = try await adapter.pendingReports()
        let deadAfterClear = try await adapter.deadLetteredReports()
        XCTAssertTrue(pendingAfterClear.isEmpty)
        XCTAssertEqual(deadAfterClear.map(\.minor), [7])
    }

    func testClearDeadLetteredReportsEmptiesSnapshotAndLeavesPending() async throws {
        let queue = InMemoryQueue()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let sdk = SelectBeaconSDK(
            engine: { FakeEngine() },
            permissionObserver: { FakePermissionObserver() },
            lifecycleObserver: { FakeLifecycleObserver() },
            clock: clock,
            queue: { _ in queue },
            networkPathObserver: { FakeNetworkPathObserver() },
            identity: AppIdentity(appKey: "select-app", appSecret: "test-secret")
        )
        let adapter = SelectBeaconAppSupport(sdk: sdk)
        let emptied = expectation(description: "Dead letter snapshot emptied")
        adapter.onDeadLetteredReportsChanged = { reports in
            if reports.isEmpty {
                emptied.fulfill()
            }
        }

        let pending = QueuedDetection(
            id: UUID(),
            uuid: SDKConfiguration.default.monitoredUUIDs[0],
            major: 1,
            minor: 3,
            bestRSSI: -50,
            latestTimestamp: clock.now,
            windowStartedAt: clock.now.addingTimeInterval(-60),
            observationCount: 2,
            location: nil,
            queuedAt: clock.now,
            uploadAttemptCount: 0
        )
        let doomed = QueuedDetection(
            id: UUID(),
            uuid: SDKConfiguration.default.monitoredUUIDs[0],
            major: 1,
            minor: 8,
            bestRSSI: -60,
            latestTimestamp: clock.now,
            windowStartedAt: clock.now.addingTimeInterval(-60),
            observationCount: 1,
            location: nil,
            queuedAt: clock.now,
            uploadAttemptCount: 0
        )
        _ = try await queue.enqueue(pending, now: clock.now)
        _ = try await queue.enqueue(doomed, now: clock.now)
        _ = try await queue.deadLetter(ids: [doomed.id], now: clock.now)

        let deadBeforeClear = try await adapter.deadLetteredReports()
        XCTAssertEqual(deadBeforeClear.map(\.minor), [8])
        try await adapter.clearDeadLetteredReports()
        await fulfillment(of: [emptied], timeout: 1)

        let remainingPending = try await adapter.pendingReports()
        let remainingDead = try await adapter.deadLetteredReports()
        XCTAssertEqual(remainingPending.map(\.minor), [3])
        XCTAssertTrue(remainingDead.isEmpty)
        XCTAssertTrue(queue.deadLetters.isEmpty)
        XCTAssertEqual(queue.records.map(\.minor), [3])
    }

    func testClearDeadLetteredReportsRefusesWhileDetectionActive() async throws {
        let queue = InMemoryQueue()
        let sdk = SelectBeaconSDK(
            engine: { FakeEngine() },
            permissionObserver: { FakePermissionObserver() },
            lifecycleObserver: { FakeLifecycleObserver() },
            clock: MutableClock(now: Date(timeIntervalSince1970: 1_000_000)),
            queue: { _ in queue },
            networkPathObserver: { FakeNetworkPathObserver() },
            identity: AppIdentity(appKey: "select-app", appSecret: "test-secret")
        )
        let adapter = SelectBeaconAppSupport(sdk: sdk)
        sdk.start()

        do {
            try await adapter.clearDeadLetteredReports()
            XCTFail("Expected clear to refuse while detection is active")
        } catch let error as PendingReportsClearError {
            XCTAssertEqual(error, .detectionActive)
        }
    }

    func testCurrentBeaconsPreserveIdentityOrder() async {
        let engine = FakeEngine()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver() },
            lifecycleObserver: { FakeLifecycleObserver() },
            clock: MutableClock(now: Date(timeIntervalSince1970: 1_000_000)),
            queue: { _ in InMemoryQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            identity: AppIdentity(appKey: "select-app", appSecret: "test-secret")
        )
        let adapter = SelectBeaconAppSupport(sdk: sdk)
        let ordered = expectation(description: "Active beacons identity-ordered")
        ordered.assertForOverFulfill = false
        adapter.onActiveBeaconsChanged = { beacons in
            if beacons.map(\.minor) == [2, 5, 9] {
                ordered.fulfill()
            }
        }

        sdk.start()
        let uuid = SDKConfiguration.default.monitoredUUIDs[0]
        engine.emit([
            DetectedBeacon(uuid: uuid, major: 2, minor: 9, rssi: -50),
            DetectedBeacon(uuid: uuid, major: 1, minor: 5, rssi: -55),
            DetectedBeacon(uuid: uuid, major: 1, minor: 2, rssi: -40),
        ])

        await fulfillment(of: [ordered], timeout: 1)
        XCTAssertEqual(adapter.currentBeacons.map(\.major), [1, 1, 2])
        XCTAssertEqual(adapter.currentBeacons.map(\.minor), [2, 5, 9])
    }
}
