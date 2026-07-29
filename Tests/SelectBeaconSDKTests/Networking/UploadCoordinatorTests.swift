import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
final class UploadCoordinatorTests: XCTestCase {
    final class FakeQueue: DurableDetectionQueue, @unchecked Sendable {
        private(set) var records: [QueuedDetection]
        private(set) var acknowledgedIDs: [[UUID]] = []

        init(records: [QueuedDetection] = []) {
            self.records = records
        }

        func enqueue(_ detection: QueuedDetection) async throws {
            records.append(detection)
        }

        func nextBatch(limit: Int) async throws -> [QueuedDetection] {
            Array(records.prefix(limit))
        }

        func acknowledge(ids: [UUID]) async throws {
            acknowledgedIDs.append(ids)
            let ids = Set(ids)
            records.removeAll { ids.contains($0.id) }
        }

        func clear() async throws {
            records.removeAll()
        }
    }

    final class FakeAuthProvider: AuthProvider {
        private(set) var tokenCallCount = 0
        var token = "batch-token"
        var error: Error?

        func validToken() async throws -> String {
            tokenCallCount += 1
            if let error {
                throw error
            }
            return token
        }
    }

    final class FakeTransport: UploadTransport {
        struct UploadError: Error {}

        private(set) var uploads: [[QueuedDetection]] = []
        private(set) var tokens: [String] = []
        var shouldFail = false
        var acknowledgeAll = true

        func upload(
            detections: [QueuedDetection],
            bearerToken: String
        ) async throws -> UploadResponse {
            uploads.append(detections)
            tokens.append(bearerToken)
            if shouldFail {
                throw UploadError()
            }
            let ids = acknowledgeAll ? detections.map(\.id) : []
            return .accepted(acknowledgedIDs: ids)
        }
    }

    final class FakePathObserver: NetworkPathObserving {
        var isSatisfied: Bool
        var onPathChanged: ((Bool) -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0

        init(isSatisfied: Bool = true) {
            self.isSatisfied = isSatisfied
        }

        func start() {
            startCount += 1
        }

        func stop() {
            stopCount += 1
        }

        func setSatisfied(_ satisfied: Bool) {
            isSatisfied = satisfied
            onPathChanged?(satisfied)
        }
    }

    @MainActor
    final class ManualScheduler: DelayedActionScheduling {
        private(set) var scheduledDelays: [TimeInterval] = []
        private var action: (@MainActor () -> Void)?

        var hasPendingAction: Bool { action != nil }

        func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
            scheduledDelays.append(delay)
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

    final class FakeDiagnostics: DiagnosticsReporting {
        private(set) var events: [DiagnosticEvent] = []

        func record(_ event: DiagnosticEvent, error: Error) {
            events.append(event)
        }
    }

    final class FakeDeviceIdentifier: DeviceIdentifying {
        var deviceId: String?

        init(deviceId: String? = "test-device-id") {
            self.deviceId = deviceId
        }
    }

    final class MutableClock: Clock {
        var now: Date

        init(now: Date) {
            self.now = now
        }
    }

    private let fleetUUID = SDKConfiguration.default.monitoredUUIDs[0]
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeDetection(minor: Int = 42, queuedAt: Date? = nil) -> QueuedDetection {
        QueuedDetectionFixtures.make(minor: minor, latestTimestamp: queuedAt ?? t0, queuedAt: queuedAt ?? t0)
    }

    private func makeCoordinator(
        queue: FakeQueue,
        auth: FakeAuthProvider = FakeAuthProvider(),
        transport: FakeTransport = FakeTransport(),
        path: FakePathObserver = FakePathObserver(),
        quiet: ManualScheduler = ManualScheduler(),
        maxAge: ManualScheduler = ManualScheduler(),
        retry: ManualScheduler = ManualScheduler(),
        clock: MutableClock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000)),
        diagnostics: FakeDiagnostics = FakeDiagnostics(),
        deviceIdentifier: FakeDeviceIdentifier = FakeDeviceIdentifier(),
        configuration: SDKConfiguration = .default,
        onQueueAcknowledged: (@MainActor () async -> Void)? = nil
    ) -> (
        UploadCoordinator,
        FakeAuthProvider,
        FakeTransport,
        FakePathObserver,
        ManualScheduler,
        ManualScheduler,
        ManualScheduler,
        MutableClock,
        FakeDiagnostics
    ) {
        let coordinator = UploadCoordinator(
            configuration: configuration,
            queueProvider: { queue },
            authProvider: auth,
            transport: transport,
            pathObserver: path,
            quietDebounceScheduler: quiet,
            maxAgeScheduler: maxAge,
            retryBackoffScheduler: retry,
            clock: clock,
            diagnosticsReporter: diagnostics,
            deviceIdentifier: deviceIdentifier,
            onQueueAcknowledged: onQueueAcknowledged
        )
        return (coordinator, auth, transport, path, quiet, maxAge, retry, clock, diagnostics)
    }

    private func waitForFlush(
        queue: FakeQueue,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !queue.records.isEmpty,
              DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if !queue.records.isEmpty {
            XCTFail(
                "Timed out waiting for upload; \(queue.records.count) record(s) remain",
                file: file,
                line: line
            )
        }
    }

    private func waitForSchedules(
        _ count: Int,
        scheduler: ManualScheduler,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while scheduler.scheduledDelays.count < count,
              DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if scheduler.scheduledDelays.count < count {
            XCTFail(
                "Timed out waiting for \(count) schedules; got \(scheduler.scheduledDelays)",
                file: file,
                line: line
            )
        }
    }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if !condition() {
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
        }
    }

    func testQuietDebounceFlushesBatchWithOneToken() async {
        let first = makeDetection(minor: 1)
        let second = makeDetection(minor: 2)
        let queue = FakeQueue(records: [first, second])
        let (coordinator, auth, transport, _, quiet, _, _, _, _) = makeCoordinator(queue: queue)

        coordinator.start()
        coordinator.setForeground(true)
        coordinator.noteSightingActivity()
        XCTAssertEqual(quiet.scheduledDelays.last, SDKConfiguration.default.sendDebounce)

        quiet.fire()
        await waitForFlush(queue: queue)

        XCTAssertEqual(auth.tokenCallCount, 1)
        XCTAssertEqual(transport.uploads.count, 1)
        XCTAssertEqual(transport.uploads.first?.map(\.minor), [1, 2])
        XCTAssertEqual(transport.tokens, ["batch-token"])
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testSightingActivityResetsQuietDebounce() {
        let queue = FakeQueue(records: [makeDetection()])
        let (coordinator, _, _, _, quiet, _, _, _, _) = makeCoordinator(queue: queue)

        coordinator.start()
        coordinator.setForeground(true)
        coordinator.noteSightingActivity()
        XCTAssertEqual(quiet.scheduledDelays.count, 1)
        coordinator.noteSightingActivity()
        XCTAssertEqual(quiet.scheduledDelays.count, 2)
        XCTAssertEqual(
            quiet.scheduledDelays,
            [
                SDKConfiguration.default.sendDebounce,
                SDKConfiguration.default.sendDebounce,
            ]
        )
    }

    func testBackgroundSightingDoesNotScheduleQuietDebounce() {
        let queue = FakeQueue(records: [makeDetection()])
        let (coordinator, _, _, _, quiet, _, _, _, _) = makeCoordinator(queue: queue)

        coordinator.start()
        coordinator.setForeground(false)
        coordinator.noteSightingActivity()
        XCTAssertTrue(quiet.scheduledDelays.isEmpty)
        XCTAssertFalse(quiet.hasPendingAction)
    }

    func testQueueChangedSchedulesMaxAgeFromOldestQueuedAt() async {
        let queuedAt = t0
        let queue = FakeQueue(records: [makeDetection(queuedAt: queuedAt)])
        let clock = MutableClock(now: t0.addingTimeInterval(100))
        let (coordinator, _, _, _, _, maxAge, _, _, _) = makeCoordinator(
            queue: queue,
            clock: clock
        )

        coordinator.start()
        await coordinator.noteQueueChanged()

        // maxQueueAge 300 - already waited 100 => delay 200
        XCTAssertEqual(maxAge.scheduledDelays.last, 200)
    }

    func testStartRestoresMaxAgeScheduleForExistingBacklog() async {
        let queue = FakeQueue(records: [makeDetection(queuedAt: t0)])
        let clock = MutableClock(now: t0.addingTimeInterval(100))
        let (coordinator, _, _, _, _, maxAge, _, _, _) = makeCoordinator(
            queue: queue,
            clock: clock
        )

        coordinator.start()
        await waitForSchedules(1, scheduler: maxAge)

        XCTAssertEqual(maxAge.scheduledDelays, [200])
    }

    func testMaxQueueAgeForcesFlushWhileNeverQuiet() async {
        let queue = FakeQueue(records: [makeDetection(queuedAt: t0)])
        let clock = MutableClock(now: t0)
        let (coordinator, auth, transport, _, quiet, maxAge, _, _, _) = makeCoordinator(
            queue: queue,
            clock: clock
        )

        coordinator.start()
        coordinator.setForeground(true)
        // Continuous sightings keep resetting quiet debounce.
        coordinator.noteSightingActivity()
        await coordinator.noteQueueChanged()

        XCTAssertEqual(quiet.scheduledDelays.last, SDKConfiguration.default.sendDebounce)
        XCTAssertEqual(maxAge.scheduledDelays.last, SDKConfiguration.default.maxQueueAge)

        // More sightings: quiet resets, max-age still pending from schedule.
        coordinator.noteSightingActivity()
        XCTAssertEqual(quiet.scheduledDelays.count, 2)

        maxAge.fire()
        await waitForFlush(queue: queue)

        XCTAssertEqual(auth.tokenCallCount, 1)
        XCTAssertEqual(transport.uploads.count, 1)
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testOpportunisticFlushOnBackgroundAndForeground() async {
        let queue = FakeQueue(records: [makeDetection(minor: 7)])
        let (coordinator, auth, transport, _, quiet, _, _, _, _) = makeCoordinator(queue: queue)

        coordinator.start()
        coordinator.setForeground(true)
        coordinator.noteSightingActivity()
        XCTAssertTrue(quiet.hasPendingAction)

        coordinator.setForeground(false)
        coordinator.flushOpportunistically()
        await waitForFlush(queue: queue)

        XCTAssertFalse(quiet.hasPendingAction)
        XCTAssertEqual(auth.tokenCallCount, 1)
        XCTAssertEqual(transport.uploads.first?.map(\.minor), [7])

        let queue2 = FakeQueue(records: [makeDetection(minor: 8)])
        let (coordinator2, auth2, transport2, _, _, _, _, _, _) = makeCoordinator(queue: queue2)
        coordinator2.start()
        coordinator2.setForeground(false)
        coordinator2.setForeground(true)
        coordinator2.flushOpportunistically()
        await waitForFlush(queue: queue2)
        XCTAssertEqual(auth2.tokenCallCount, 1)
        XCTAssertEqual(transport2.uploads.first?.map(\.minor), [8])
    }

    func testOfflineTriggerDoesNotSendOrScheduleBackoff() async {
        let queue = FakeQueue(records: [makeDetection()])
        let path = FakePathObserver(isSatisfied: false)
        let (coordinator, auth, transport, _, quiet, _, retry, _, _) = makeCoordinator(
            queue: queue,
            path: path
        )

        coordinator.start()
        coordinator.setForeground(true)
        coordinator.noteSightingActivity()
        quiet.fire()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(auth.tokenCallCount, 0)
        XCTAssertTrue(transport.uploads.isEmpty)
        XCTAssertEqual(queue.records.count, 1)
        XCTAssertTrue(retry.scheduledDelays.isEmpty)
    }

    func testConnectivityReturnFlushesImmediately() async {
        let queue = FakeQueue(records: [makeDetection(minor: 3)])
        let path = FakePathObserver(isSatisfied: false)
        let (coordinator, auth, transport, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            path: path
        )

        coordinator.start()
        path.setSatisfied(true)
        await waitForFlush(queue: queue)

        XCTAssertEqual(auth.tokenCallCount, 1)
        XCTAssertEqual(transport.uploads.first?.map(\.minor), [3])
    }

    func testStopStartRearmsPathObservationAndConnectivityFlush() async {
        let queue = FakeQueue(records: [makeDetection(minor: 4)])
        let path = FakePathObserver(isSatisfied: false)
        let (coordinator, _, transport, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            path: path
        )

        coordinator.start()
        coordinator.stop()
        coordinator.start()
        path.setSatisfied(true)
        await waitForFlush(queue: queue)

        XCTAssertEqual(path.startCount, 2)
        XCTAssertEqual(path.stopCount, 1)
        XCTAssertEqual(transport.uploads.first?.map(\.minor), [4])
    }

    func testFailedUploadRetainsQueueAndReportsDiagnostics() async {
        let queue = FakeQueue(records: [makeDetection()])
        let transport = FakeTransport()
        transport.shouldFail = true
        let diagnostics = FakeDiagnostics()
        let (coordinator, _, _, _, _, _, retry, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            diagnostics: diagnostics
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(queue.records.count, 1)
        XCTAssertEqual(diagnostics.events, [.uploadFailed])
        XCTAssertEqual(retry.scheduledDelays.last, SDKConfiguration.default.uploadRetryBackoff)
    }

    func testRetryBackoffDoublesAndCapsAtMaximum() async {
        let queue = FakeQueue(records: [makeDetection()])
        let transport = FakeTransport()
        transport.shouldFail = true
        let retry = ManualScheduler()
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            retry: retry
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        let expected: [TimeInterval] = [15, 30, 60, 120, 240, 300, 300]
        for index in expected.indices {
            await waitForSchedules(index + 1, scheduler: retry)
            XCTAssertEqual(retry.scheduledDelays[index], expected[index])
            if index < expected.count - 1 {
                retry.fire()
            }
        }

        XCTAssertEqual(queue.records.count, 1)
    }

    func testNoteQueueChangedDoesNotScheduleQuietDebounce() async {
        let queue = FakeQueue(records: [makeDetection()])
        let (coordinator, _, _, _, quiet, maxAge, _, _, _) = makeCoordinator(queue: queue)

        coordinator.start()
        coordinator.setForeground(true)
        await coordinator.noteQueueChanged()

        XCTAssertTrue(quiet.scheduledDelays.isEmpty)
        XCTAssertEqual(maxAge.scheduledDelays.last, SDKConfiguration.default.maxQueueAge)
    }

    func testAcknowledgeInvokesQueueAcknowledgedCallback() async {
        let queue = FakeQueue(records: [makeDetection(minor: 9)])
        var ackCount = 0
        let coordinator = UploadCoordinator(
            configuration: .default,
            queueProvider: { queue },
            authProvider: FakeAuthProvider(),
            transport: FakeTransport(),
            pathObserver: FakePathObserver(),
            quietDebounceScheduler: ManualScheduler(),
            maxAgeScheduler: ManualScheduler(),
            retryBackoffScheduler: ManualScheduler(),
            clock: MutableClock(now: t0),
            deviceIdentifier: FakeDeviceIdentifier(),
            onQueueAcknowledged: { ackCount += 1 }
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForFlush(queue: queue)

        XCTAssertEqual(ackCount, 1)
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testEmptyAcknowledgementStopsFlushWithoutSpinning() async {
        let queue = FakeQueue(records: [makeDetection(minor: 11)])
        let transport = FakeTransport()
        transport.acknowledgeAll = false
        let retry = ManualScheduler()
        let diagnostics = FakeDiagnostics()
        var ackCount = 0
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            retry: retry,
            diagnostics: diagnostics,
            onQueueAcknowledged: { ackCount += 1 }
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(transport.uploads.count, 1)
        XCTAssertEqual(queue.records.count, 1)
        XCTAssertEqual(ackCount, 0)
        XCTAssertEqual(diagnostics.events, [.uploadFailed])
        XCTAssertEqual(retry.scheduledDelays.last, SDKConfiguration.default.uploadRetryBackoff)
    }

    func testMultiBatchFlushInvokesAcknowledgementCallbackPerBatch() async {
        let queue = FakeQueue(records: [
            makeDetection(minor: 1),
            makeDetection(minor: 2),
        ])
        let defaults = SDKConfiguration.default
        let configuration = SDKConfiguration(
            monitoredUUIDs: defaults.monitoredUUIDs,
            windowDuration: defaults.windowDuration,
            absenceTimeout: defaults.absenceTimeout,
            sendDebounce: defaults.sendDebounce,
            maxQueueAge: defaults.maxQueueAge,
            uploadBatchLimit: 1,
            uploadRetryBackoff: defaults.uploadRetryBackoff,
            uploadRetryBackoffMax: defaults.uploadRetryBackoffMax,
            locationAccuracy: defaults.locationAccuracy,
            locationDistanceFilterMeters: defaults.locationDistanceFilterMeters,
            useSignificantChangeBaseline: defaults.useSignificantChangeBaseline
        )
        var ackCount = 0
        let (coordinator, _, transport, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            configuration: configuration,
            onQueueAcknowledged: { ackCount += 1 }
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForFlush(queue: queue)
        await waitUntil("two acknowledgement callbacks") { ackCount == 2 }

        XCTAssertEqual(transport.uploads.count, 2)
        XCTAssertEqual(ackCount, 2)
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testMissingDeviceIdentifierSkipsUploadAndSchedulesRetry() async {
        let queue = FakeQueue(records: [makeDetection(minor: 5)])
        let transport = FakeTransport()
        let retry = ManualScheduler()
        let diagnostics = FakeDiagnostics()
        let (coordinator, auth, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            retry: retry,
            diagnostics: diagnostics,
            deviceIdentifier: FakeDeviceIdentifier(deviceId: nil)
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(transport.uploads.count, 0)
        XCTAssertEqual(auth.tokenCallCount, 0)
        XCTAssertEqual(queue.records.count, 1)
        XCTAssertEqual(diagnostics.events, [.deviceIdentifierUnavailable])
        XCTAssertEqual(retry.scheduledDelays.last, SDKConfiguration.default.uploadRetryBackoff)
    }
}
