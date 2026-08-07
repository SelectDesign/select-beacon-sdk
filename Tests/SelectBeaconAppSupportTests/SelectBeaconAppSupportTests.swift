import XCTest
import CoreLocation
@testable import SelectBeaconAppSupport
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
final class SelectBeaconAppSupportTests: XCTestCase {
    final class FakeEngine: DetectionEngine {
        var onBeacons: (([DetectedBeacon]) -> Void)?

        func start(uuids: [UUID]) {}
        func stop() {}

        func emit(_ beacons: [DetectedBeacon]) {
            onBeacons?(beacons)
        }
    }

    final class FakePermissionObserver: PermissionObserver {
        let authorization: LocationAuthorization = .always
        var onAuthorizationChanged: ((LocationAuthorization) -> Void)?
    }

    final class FakeLifecycleObserver: ApplicationLifecycleObserving {
        private(set) var isActive: Bool
        var onActivityChanged: ((Bool) -> Void)?

        init(isActive: Bool = true) {
            self.isActive = isActive
        }

        func setActive(_ isActive: Bool) {
            self.isActive = isActive
            onActivityChanged?(isActive)
        }
    }

    @MainActor
    final class InMemoryQueue: DurableDetectionQueue {
        private(set) var records: [QueuedDetection] = []
        private(set) var deadLetters: [QueuedDetection] = []
        var maxQueueSize: Int = SDKConfiguration.default.maxQueueSize
        var maxRecordAge: TimeInterval = SDKConfiguration.default.maxRecordAge

        func enqueue(_ detection: QueuedDetection, now: Date) async throws -> EnqueueResult {
            var evicted = 0
            let cutoff = now.addingTimeInterval(-maxRecordAge)
            let beforeAge = records.count
            records.removeAll { $0.queuedAt < cutoff }
            evicted += beforeAge - records.count
            while records.count >= maxQueueSize {
                records.removeFirst()
                evicted += 1
            }
            records.append(detection)
            return EnqueueResult(evictedCount: evicted)
        }

        func nextBatch(limit: Int) async throws -> [QueuedDetection] {
            Array(records.prefix(limit))
        }

        func acknowledge(ids: [UUID]) async throws {
            let ids = Set(ids)
            records.removeAll { ids.contains($0.id) }
        }

        func recordUploadAttempts(for ids: [UUID]) async throws {
            let idSet = Set(ids)
            records = records.map { record in
                guard idSet.contains(record.id) else { return record }
                return record.withUploadAttemptCount(record.uploadAttemptCount + 1)
            }
        }

        func deadLetter(ids: [UUID], now: Date) async throws -> EnqueueResult {
            let idSet = Set(ids)
            let moving = records.filter { idSet.contains($0.id) }
            records.removeAll { idSet.contains($0.id) }
            deadLetters.append(contentsOf: moving)
            let evicted = pruneDeadLetters(now: now)
            return EnqueueResult(evictedCount: evicted)
        }

        func deadLetteredRecords(now: Date) async throws -> DeadLetterSnapshot {
            let evicted = pruneDeadLetters(now: now)
            return DeadLetterSnapshot(records: deadLetters, evictedCount: evicted)
        }

        func clear() async throws {
            records.removeAll()
        }

        func clearDeadLetters() async throws {
            deadLetters.removeAll()
        }

        private func pruneDeadLetters(now: Date) -> Int {
            var evicted = 0
            let cutoff = now.addingTimeInterval(-maxRecordAge)
            let beforeAge = deadLetters.count
            deadLetters.removeAll { $0.queuedAt < cutoff }
            evicted += beforeAge - deadLetters.count
            while deadLetters.count > maxQueueSize {
                deadLetters.removeFirst()
                evicted += 1
            }
            return evicted
        }
    }

    final class MutableClock: Clock {
        var now: Date

        init(now: Date) {
            self.now = now
        }
    }

    @MainActor
    final class ManualDelayedActionScheduler: DelayedActionScheduling {
        private var action: (@MainActor () -> Void)?

        func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        func cancel() {
            action = nil
        }

        func fire() {
            let action = action
            self.action = nil
            action?()
        }
    }

    final class FakeNetworkPathObserver: NetworkPathObserving {
        var isSatisfied = true
        var onPathChanged: ((Bool) -> Void)?

        func start() {}
        func stop() {}
    }

    actor BlockingQueue: DurableDetectionQueue {
        private var records: [QueuedDetection] = []
        private var availableStarts = 0
        private var availableCompletions = 0
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var completionWaiter: CheckedContinuation<Void, Never>?
        private var writePermits: [CheckedContinuation<Void, Never>] = []

        func enqueue(_ detection: QueuedDetection, now: Date) async throws -> EnqueueResult {
            _ = now
            await withCheckedContinuation { permit in
                writePermits.append(permit)
                signalWriteStart()
            }
            records.append(detection)
            signalWriteCompletion()
            return .none
        }

        func nextBatch(limit: Int) async throws -> [QueuedDetection] {
            Array(records.prefix(limit))
        }

        func acknowledge(ids: [UUID]) async throws {
            let ids = Set(ids)
            records.removeAll { ids.contains($0.id) }
        }

        func recordUploadAttempts(for ids: [UUID]) async throws {
            let idSet = Set(ids)
            records = records.map { record in
                guard idSet.contains(record.id) else { return record }
                return record.withUploadAttemptCount(record.uploadAttemptCount + 1)
            }
        }

        func deadLetter(ids: [UUID], now: Date) async throws -> EnqueueResult {
            _ = now
            let idSet = Set(ids)
            records.removeAll { idSet.contains($0.id) }
            return .none
        }

        func deadLetteredRecords(now: Date) async throws -> DeadLetterSnapshot {
            _ = now
            return DeadLetterSnapshot(records: [], evictedCount: 0)
        }

        func clear() async throws {
            records.removeAll()
        }

        func clearDeadLetters() async throws {}

        func waitForWriteStart() async {
            if availableStarts > 0 {
                availableStarts -= 1
                return
            }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func releaseNextWrite() {
            writePermits.removeFirst().resume()
        }

        func waitForWriteCompletion() async {
            if availableCompletions > 0 {
                availableCompletions -= 1
                return
            }
            await withCheckedContinuation { completionWaiter = $0 }
        }

        private func signalWriteStart() {
            if let startWaiter {
                self.startWaiter = nil
                startWaiter.resume()
            } else {
                availableStarts += 1
            }
        }

        private func signalWriteCompletion() {
            if let completionWaiter {
                self.completionWaiter = nil
                completionWaiter.resume()
            } else {
                availableCompletions += 1
            }
        }
    }

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
