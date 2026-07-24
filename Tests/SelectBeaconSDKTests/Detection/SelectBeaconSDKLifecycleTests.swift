import XCTest
import CoreLocation
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
final class SelectBeaconSDKTests: XCTestCase {
    final class FakeEngine: DetectionEngine {
        var onBeacons: (([DetectedBeacon]) -> Void)?
        private(set) var startedUUIDs: [[UUID]] = []
        private(set) var stopCount = 0

        func start(uuids: [UUID]) {
            startedUUIDs.append(uuids)
        }

        func stop() {
            stopCount += 1
        }

        func emit(_ beacons: [DetectedBeacon]) {
            onBeacons?(beacons)
        }
    }

    final class FakePermissionObserver: PermissionObserver {
        var authorization: LocationAuthorization
        var onAuthorizationChanged: ((LocationAuthorization) -> Void)?

        init(authorization: LocationAuthorization) {
            self.authorization = authorization
        }

        func setAuthorization(_ authorization: LocationAuthorization) {
            self.authorization = authorization
            onAuthorizationChanged?(authorization)
        }
    }

    final class FakeLifecycleObserver: ApplicationLifecycleObserving {
        var isActive: Bool
        var onActivityChanged: ((Bool) -> Void)?

        init(isActive: Bool) {
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

        func enqueue(_ detection: QueuedDetection) async throws {
            records.append(detection)
        }

        func nextBatch(limit: Int) async throws -> [QueuedDetection] {
            Array(records.prefix(limit))
        }

        func acknowledge(ids: [UUID]) async throws {
            let ids = Set(ids)
            records.removeAll { ids.contains($0.id) }
        }

        func clear() async throws {
            records.removeAll()
        }
    }

    @MainActor
    final class FailingQueue: DurableDetectionQueue {
        struct WriteError: Error {}

        func enqueue(_ detection: QueuedDetection) async throws {
            throw WriteError()
        }

        func nextBatch(limit: Int) async throws -> [QueuedDetection] {
            []
        }

        func acknowledge(ids: [UUID]) async throws {}

        func clear() async throws {
            throw WriteError()
        }
    }

    @MainActor
    final class UnreadableQueue: DurableDetectionQueue {
        private var cleared = false

        func enqueue(_ detection: QueuedDetection) async throws {
            guard !cleared else { return }
            throw DurableDetectionQueueError.unreadableStoredDetections
        }

        func nextBatch(limit: Int) async throws -> [QueuedDetection] {
            if cleared { return [] }
            throw DurableDetectionQueueError.unreadableStoredDetections
        }

        func acknowledge(ids: [UUID]) async throws {
            guard !cleared else { return }
            throw DurableDetectionQueueError.unreadableStoredDetections
        }

        func clear() async throws {
            cleared = true
        }
    }

    actor BlockingQueue: DurableDetectionQueue {
        private var records: [QueuedDetection] = []
        private var availableStarts = 0
        private var availableCompletions = 0
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var completionWaiter: CheckedContinuation<Void, Never>?
        private var writePermits: [CheckedContinuation<Void, Never>] = []

        func enqueue(_ detection: QueuedDetection) async throws {
            await withCheckedContinuation { permit in
                writePermits.append(permit)
                signalWriteStart()
            }
            records.append(detection)
            signalWriteCompletion()
        }

        func nextBatch(limit: Int) async throws -> [QueuedDetection] {
            Array(records.prefix(limit))
        }

        func acknowledge(ids: [UUID]) async throws {
            let ids = Set(ids)
            records.removeAll { ids.contains($0.id) }
        }

        func clear() async throws {
            records.removeAll()
        }

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

    final class FakeDiagnosticsReporter: DiagnosticsReporting {
        private(set) var events: [DiagnosticEvent] = []

        func record(_ event: DiagnosticEvent, error: Error) {
            events.append(event)
        }
    }

    struct FixedClock: Clock {
        let now: Date
    }

    final class MutableClock: Clock {
        var now: Date

        init(now: Date) {
            self.now = now
        }
    }

    @MainActor
    final class ManualPresenceExpiryScheduler: PresenceExpiryScheduling {
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

    final class FakeLocationProvider: LocationProviding {
        var currentLocation: LocationFix?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var isDetecting = false

        func start() {
            startCount += 1
        }

        func stop() {
            stopCount += 1
            isDetecting = false
        }

        func setDetecting(_ isDetecting: Bool) {
            self.isDetecting = isDetecting
        }
    }

    final class FakeNetworkPathObserver: NetworkPathObserving {
        var isSatisfied = true
        var onPathChanged: ((Bool) -> Void)?

        func start() {}
        func stop() {}
    }

    private let fleetUUID = SDKConfiguration.default.monitoredUUIDs[0]

    private func makeSDK(
        authorization: LocationAuthorization = .always,
        isActive: Bool = true,
        identity: AppIdentity? = AppIdentity(appKey: "customer-key"),
        environment: SelectBeaconSDK.Environment = .production,
        locationProvider: FakeLocationProvider = FakeLocationProvider(),
        clock: MutableClock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000)),
        absenceScheduler: ManualPresenceExpiryScheduler = ManualPresenceExpiryScheduler()
    ) -> (
        sdk: SelectBeaconSDK,
        engine: FakeEngine,
        permission: FakePermissionObserver,
        lifecycle: FakeLifecycleObserver,
        queue: InMemoryQueue,
        locationProvider: FakeLocationProvider,
        clock: MutableClock,
        absenceScheduler: ManualPresenceExpiryScheduler
    ) {
        let engine = FakeEngine()
        let permission = FakePermissionObserver(authorization: authorization)
        let lifecycle = FakeLifecycleObserver(isActive: isActive)
        let queue = InMemoryQueue()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { permission },
            lifecycleObserver: { lifecycle },
            clock: clock,
            queue: { _ in queue },
            locationProvider: { locationProvider },
            networkPathObserver: { FakeNetworkPathObserver() },
            absenceExpiryScheduler: absenceScheduler,
            identity: identity,
            environment: environment
        )
        return (sdk, engine, permission, lifecycle, queue, locationProvider, clock, absenceScheduler)
    }

    private func makeSDK(
        engine: FakeEngine,
        queue: @escaping (String) -> any DurableDetectionQueue,
        lifecycle: FakeLifecycleObserver = FakeLifecycleObserver(isActive: true),
        clock: MutableClock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000)),
        absenceScheduler: ManualPresenceExpiryScheduler = ManualPresenceExpiryScheduler()
    ) -> SelectBeaconSDK {
        SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { lifecycle },
            clock: clock,
            queue: queue,
            networkPathObserver: { FakeNetworkPathObserver() },
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "customer-key")
        )
    }

    private func closeOpenWindows(
        clock: MutableClock,
        absenceScheduler: ManualPresenceExpiryScheduler
    ) {
        clock.now = clock.now.addingTimeInterval(SDKConfiguration.default.absenceTimeout + 0.1)
        absenceScheduler.fire()
    }

    private func waitForPersistence(queue: InMemoryQueue? = nil, minCount: Int = 1) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let queue, queue.records.count >= minCount {
                await Task.yield()
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await Task.yield()
    }

    private func testURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Invalid test URL: \(string)")
            return URL(fileURLWithPath: "/invalid-test-url")
        }
        return url
    }

    func testProductionEnvironmentIsDefault() {
        let fixture = makeSDK()

        XCTAssertEqual(fixture.sdk.configuredEnvironment, .production)
        XCTAssertEqual(fixture.sdk.configuredEndpoint?.baseURL, APIEndpointDefaults.production)
    }

    func testStagingEnvironmentRetainsCallerSuppliedEndpoint() {
        let stagingURL = testURL("https://staging-eu.example.com")
        let fixture = makeSDK(environment: .staging(baseURL: stagingURL))

        XCTAssertEqual(fixture.sdk.configuredEnvironment, .staging(baseURL: stagingURL))
        XCTAssertEqual(fixture.sdk.configuredEndpoint?.baseURL, stagingURL.absoluteString)
    }

    func testDifferentStagingEnvironmentsRemainDistinct() {
        let firstURL = testURL("https://staging-one.example.com")
        let secondURL = testURL("https://staging-two.example.com")
        let first = makeSDK(environment: .staging(baseURL: firstURL))
        let second = makeSDK(environment: .staging(baseURL: secondURL))

        XCTAssertNotEqual(first.sdk.configuredEndpoint, second.sdk.configuredEndpoint)
    }

    func testHTTPStagingEndpointIsSupported() {
        let stagingURL = testURL("http://staging.example.com")
        let fixture = makeSDK(environment: .staging(baseURL: stagingURL))

        XCTAssertEqual(fixture.sdk.configuredEndpoint?.baseURL, stagingURL.absoluteString)
    }

    func testNonHTTPStagingEndpointDoesNotConfigureSDK() {
        let fixture = makeSDK(
            environment: .staging(baseURL: URL(fileURLWithPath: "/tmp/staging"))
        )

        fixture.sdk.start()

        XCTAssertNil(fixture.sdk.configuredEnvironment)
        XCTAssertTrue(fixture.engine.startedUUIDs.isEmpty)
    }

    func testConfigurationCannotChangeAfterStart() {
        let fixture = makeSDK()
        fixture.sdk.start()
        let stagingURL = testURL("https://staging.example.com")
        let stagingIdentity = AppIdentity(appKey: "staging-key")
        guard let stagingIdentity else {
            return XCTFail("Test app identity should be valid")
        }

        fixture.sdk.configure(
            identity: stagingIdentity,
            environment: .staging(baseURL: stagingURL)
        )

        XCTAssertEqual(fixture.sdk.configuredEnvironment, .production)
        XCTAssertEqual(fixture.sdk.configuredEndpoint?.baseURL, APIEndpointDefaults.production)
    }

    func testInvalidReplacementConfigurationClearsPriorEnablement() {
        let fixture = makeSDK()

        fixture.sdk.configure(
            identity: AppIdentity(appKey: "replacement-key")!,
            environment: .staging(baseURL: URL(fileURLWithPath: "/invalid"))
        )
        fixture.sdk.start()

        XCTAssertNil(fixture.sdk.configuredEnvironment)
        XCTAssertTrue(fixture.engine.startedUUIDs.isEmpty)
        XCTAssertEqual(fixture.sdk.operationalStatus, .degraded(.startRequestedBeforeConfiguration))
    }

    func testPreStartReconfigurationCreatesQueueForNewNamespace() async throws {
        let engine = FakeEngine()
        let permission = FakePermissionObserver(authorization: .always)
        let lifecycle = FakeLifecycleObserver(isActive: true)
        var storageIdentifiers: [String] = []
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { permission },
            lifecycleObserver: { lifecycle },
            clock: FixedClock(now: Date(timeIntervalSince1970: 1_000_000)),
            queue: { storageIdentifier in
                storageIdentifiers.append(storageIdentifier)
                return InMemoryQueue()
            },
            identity: AppIdentity(appKey: "first-key")
        )

        _ = try await sdk.selectPendingReports()
        sdk.configure(
            identity: AppIdentity(appKey: "second-key")!,
            environment: .staging(baseURL: testURL("https://staging.example.com"))
        )
        _ = try await sdk.selectPendingReports()

        XCTAssertEqual(storageIdentifiers.count, 2)
        XCTAssertNotEqual(storageIdentifiers[0], storageIdentifiers[1])
    }

    func testUnconfiguredStartIsQuiet() {
        let fixture = makeSDK(identity: nil)

        fixture.sdk.start()

        XCTAssertTrue(fixture.engine.startedUUIDs.isEmpty)
    }

    func testAlwaysAuthorizationStartsSingleSelectUUID() {
        let fixture = makeSDK(authorization: .always, isActive: false)

        fixture.sdk.start()

        XCTAssertEqual(fixture.engine.startedUUIDs, [[fleetUUID]])
    }

    func testWhenInUseAuthorizationOnlyRangesInForeground() {
        let fixture = makeSDK(authorization: .whenInUse, isActive: true)

        fixture.sdk.start()
        XCTAssertEqual(fixture.engine.startedUUIDs.count, 1)

        fixture.lifecycle.setActive(false)
        XCTAssertEqual(fixture.engine.stopCount, 1)

        fixture.lifecycle.setActive(true)
        XCTAssertEqual(fixture.engine.startedUUIDs.count, 2)
    }

    func testNotDeterminedIsQuietUntilHostGrantsAuthorization() {
        let fixture = makeSDK(authorization: .notDetermined)

        fixture.sdk.start()
        XCTAssertTrue(fixture.engine.startedUUIDs.isEmpty)
        XCTAssertEqual(fixture.sdk.operationalStatus, .awaitingPermission)

        fixture.permission.setAuthorization(.always)
        XCTAssertEqual(fixture.engine.startedUUIDs, [[fleetUUID]])
        XCTAssertEqual(fixture.sdk.operationalStatus, .ranging)
    }

    func testAuthorizationRevocationStopsRangingWithoutHostError() {
        let fixture = makeSDK()

        fixture.sdk.start()
        fixture.permission.setAuthorization(.unavailable)

        XCTAssertEqual(fixture.engine.stopCount, 1)
        XCTAssertEqual(
            fixture.sdk.operationalStatus,
            .degraded(.locationPermissionUnavailable)
        )
    }

    func testStopPreventsLaterPermissionChangesFromRestartingRanging() {
        let fixture = makeSDK()

        fixture.sdk.start()
        fixture.sdk.stop()
        fixture.permission.setAuthorization(.whenInUse)

        XCTAssertEqual(fixture.engine.startedUUIDs.count, 1)
        XCTAssertEqual(fixture.engine.stopCount, 1)
    }

    func testStopAndStartBeginsNewWindowSession() async {
        let fixture = makeSDK()
        let beacon = DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55)
        var received: [DetectedBeacon] = []
        fixture.sdk.onDetection = { received.append($0) }

        fixture.sdk.start()
        fixture.engine.emit([beacon])
        fixture.sdk.stop()
        await waitForPersistence(queue: fixture.queue, minCount: 1)
        fixture.sdk.start()
        fixture.engine.emit([beacon])
        fixture.sdk.stop()
        await waitForPersistence(queue: fixture.queue, minCount: 2)

        XCTAssertEqual(received.count, 2)
    }

    func testWindowCloseEnqueuesBeforeHostCallback() async {
        let fixture = makeSDK()
        fixture.sdk.start()
        let beacon = DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55)
        var queueCountDuringCallback = 0
        fixture.sdk.onDetection = { _ in
            queueCountDuringCallback = fixture.queue.records.count
        }

        fixture.engine.emit([beacon])
        XCTAssertTrue(fixture.queue.records.isEmpty)
        closeOpenWindows(clock: fixture.clock, absenceScheduler: fixture.absenceScheduler)
        await waitForPersistence(queue: fixture.queue)

        XCTAssertEqual(queueCountDuringCallback, 1)
        XCTAssertEqual(fixture.queue.records.count, 1)
        XCTAssertEqual(fixture.queue.records.first?.observationCount, 1)
    }

    func testInWindowSightingsAggregateIntoOneReport() async {
        let fixture = makeSDK()
        fixture.sdk.start()
        let beacon = DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55)
        var received: [DetectedBeacon] = []
        fixture.sdk.onDetection = { received.append($0) }

        fixture.engine.emit([beacon])
        fixture.engine.emit([DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -70)])
        closeOpenWindows(clock: fixture.clock, absenceScheduler: fixture.absenceScheduler)
        await waitForPersistence(queue: fixture.queue)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(fixture.queue.records.count, 1)
        XCTAssertEqual(fixture.queue.records.first?.observationCount, 2)
        XCTAssertEqual(fixture.queue.records.first?.bestRSSI, -55)
    }

    func testObservationCallbacksDistinguishWindowUpdateFromReport() async {
        let fixture = makeSDK()
        let beacon = DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55)
        var observations: [BeaconObservation] = []
        var activityUpdates: [BeaconActivityUpdate] = []
        var reportStatusUpdates: [BeaconReportStatusUpdate] = []
        fixture.sdk.onBeaconObserved = { observations.append($0) }
        fixture.sdk.onBeaconActivityUpdated = { activityUpdates.append($0) }
        fixture.sdk.onBeaconReportStatusUpdated = { reportStatusUpdates.append($0) }

        fixture.sdk.start()
        fixture.engine.emit([beacon])
        fixture.engine.emit([beacon])
        XCTAssertEqual(observations.count, 2)
        XCTAssertTrue(
            activityUpdates.allSatisfy { $0.disposition == .windowUpdated && $0.report == nil }
        )

        closeOpenWindows(clock: fixture.clock, absenceScheduler: fixture.absenceScheduler)
        await waitForPersistence(queue: fixture.queue)

        XCTAssertTrue(
            reportStatusUpdates.contains { $0.report.status == .queued }
        )
    }

    func testSelectSPIProvidesActiveAndPendingSnapshots() async throws {
        let fixture = makeSDK()
        fixture.sdk.start()
        fixture.engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 1, rssi: -55),
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 2, rssi: -60),
        ])
        closeOpenWindows(clock: fixture.clock, absenceScheduler: fixture.absenceScheduler)
        await waitForPersistence(queue: fixture.queue, minCount: 2)

        XCTAssertEqual(
            fixture.sdk.selectActiveBeaconObservations.map(\.minor),
            [1, 2]
        )
        let pendingReports = try await fixture.sdk.selectPendingReports()
        XCTAssertEqual(Set(pendingReports.map(\.minor)), Set([1, 2]))

        fixture.sdk.stop()
        XCTAssertTrue(fixture.sdk.selectActiveBeaconObservations.isEmpty)
    }

    func testNilLocationIsPreservedOnFinalizedReport() async {
        let locationProvider = FakeLocationProvider()
        locationProvider.currentLocation = nil
        let fixture = makeSDK(locationProvider: locationProvider)
        fixture.sdk.start()
        fixture.engine.emit([DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55)])
        closeOpenWindows(clock: fixture.clock, absenceScheduler: fixture.absenceScheduler)
        await waitForPersistence(queue: fixture.queue)

        XCTAssertNil(fixture.queue.records.first?.location)
    }

    func testCachedLocationIsStampedOntoFinalizedReport() async {
        let locationProvider = FakeLocationProvider()
        locationProvider.currentLocation = LocationFix(
            latitude: 40.7,
            longitude: -74.0,
            horizontalAccuracy: 100,
            timestamp: Date(timeIntervalSince1970: 999_000)
        )
        let fixture = makeSDK(locationProvider: locationProvider)
        fixture.sdk.start()
        fixture.engine.emit([DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55)])
        closeOpenWindows(clock: fixture.clock, absenceScheduler: fixture.absenceScheduler)
        await waitForPersistence(queue: fixture.queue)

        XCTAssertEqual(fixture.queue.records.first?.location?.latitude, 40.7)
        XCTAssertEqual(fixture.locationProvider.startCount, 1)
        XCTAssertTrue(fixture.locationProvider.isDetecting)
    }

    func testActiveBeaconExpiresAfterAbsenceTimeout() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let engine = FakeEngine()
        let clock = MutableClock(now: now)
        let expiryScheduler = ManualPresenceExpiryScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { FakeLifecycleObserver(isActive: true) },
            clock: clock,
            queue: { _ in InMemoryQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            presenceExpiryScheduler: expiryScheduler,
            identity: AppIdentity(appKey: "customer-key")
        )

        sdk.start()
        engine.emit([DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55)])
        XCTAssertEqual(sdk.selectActiveBeaconObservations.map(\.minor), [42])

        clock.now = now.addingTimeInterval(SDKConfiguration.default.absenceTimeout)
        expiryScheduler.fire()

        XCTAssertTrue(sdk.selectActiveBeaconObservations.isEmpty)
    }

    func testStopDuringWriteSuppressesStaleCallback() async {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let absenceScheduler = ManualPresenceExpiryScheduler()
        let sdk = makeSDK(
            engine: engine,
            queue: { _ in queue },
            clock: clock,
            absenceScheduler: absenceScheduler
        )
        let callback = expectation(description: "No callback after stop")
        callback.isInverted = true
        sdk.onDetection = { _ in callback.fulfill() }

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await queue.waitForWriteStart()

        sdk.stop()
        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [callback], timeout: 0.1)
    }

    func testPausedRangingDeliversCompletedPendingReportUpdate() async {
        let engine = FakeEngine()
        let permission = FakePermissionObserver(authorization: .whenInUse)
        let lifecycle = FakeLifecycleObserver(isActive: true)
        let queue = BlockingQueue()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let absenceScheduler = ManualPresenceExpiryScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { permission },
            lifecycleObserver: { lifecycle },
            clock: clock,
            queue: { _ in queue },
            networkPathObserver: { FakeNetworkPathObserver() },
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "customer-key")
        )
        let update = expectation(description: "Pending report update after pause")
        sdk.onSelectPendingReportsChanged = { reports in
            XCTAssertEqual(reports.map(\.minor), [42])
            update.fulfill()
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await queue.waitForWriteStart()

        lifecycle.setActive(false)
        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [update], timeout: 1)
    }

    func testStopFinalizesOpenWindowsAndDelivers() async throws {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let sdk = makeSDK(engine: engine, queue: { _ in queue })
        let callback = expectation(description: "Callback after stop finalize")
        sdk.onDetection = { _ in callback.fulfill() }

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        sdk.stop()

        await fulfillment(of: [callback], timeout: 1)
        let queuedDetections = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(queuedDetections.count, 1)
        XCTAssertEqual(queuedDetections.first?.minor, 42)
    }

    func testStopFinalizeSurvivesImmediateStart() async throws {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = makeSDK(engine: engine, queue: { _ in queue })
        let callback = expectation(description: "Stop-finalize delivered after restart")
        sdk.onDetection = { beacon in
            XCTAssertEqual(beacon.minor, 42)
            callback.fulfill()
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        // Leave the window open so stop() must finalize and enqueue it.
        sdk.stop()
        await queue.waitForWriteStart()

        // Immediate restart must not invalidate the stop-finalize enqueue.
        sdk.start()

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [callback], timeout: 1)

        let queuedDetections = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(queuedDetections.map(\.minor), [42])
    }

    func testStopAndStartDoesNotDeliverOldSessionCallback() async {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let absenceScheduler = ManualPresenceExpiryScheduler()
        let sdk = makeSDK(
            engine: engine,
            queue: { _ in queue },
            clock: clock,
            absenceScheduler: absenceScheduler
        )
        var callbacks: [Int] = []
        let callbackExpectation = expectation(description: "New session callback only")
        sdk.onDetection = { beacon in
            callbacks.append(beacon.minor)
            callbackExpectation.fulfill()
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 1, rssi: -55),
        ])
        closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await queue.waitForWriteStart()

        sdk.stop()
        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 2, rssi: -55),
        ])
        closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await queue.waitForWriteStart()
        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [callbackExpectation], timeout: 1)

        XCTAssertEqual(callbacks, [2])
    }

    func testRangingBatchesPreserveQueueAndCallbackOrder() async {
        let fixture = makeSDK()
        let first = DetectedBeacon(uuid: fleetUUID, major: 1, minor: 1, rssi: -55)
        let second = DetectedBeacon(uuid: fleetUUID, major: 1, minor: 2, rssi: -55)
        let third = DetectedBeacon(uuid: fleetUUID, major: 1, minor: 3, rssi: -55)
        var callbacks: [Int] = []
        let callbackExpectation = expectation(description: "All callbacks")
        callbackExpectation.expectedFulfillmentCount = 3
        fixture.sdk.onDetection = { beacon in
            callbacks.append(beacon.minor)
            callbackExpectation.fulfill()
        }

        fixture.sdk.start()
        fixture.engine.emit([first, second])
        fixture.engine.emit([third])
        closeOpenWindows(clock: fixture.clock, absenceScheduler: fixture.absenceScheduler)

        await fulfillment(of: [callbackExpectation], timeout: 1)

        XCTAssertEqual(callbacks, [1, 2, 3])
        XCTAssertEqual(fixture.queue.records.map(\.minor), [1, 2, 3])
    }

    func testUnknownRSSIIsIgnored() {
        let fixture = makeSDK()
        fixture.sdk.start()
        var received: [DetectedBeacon] = []
        fixture.sdk.onDetection = { received.append($0) }

        fixture.engine.emit([DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: 0)])
        closeOpenWindows(clock: fixture.clock, absenceScheduler: fixture.absenceScheduler)

        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(fixture.queue.records.isEmpty)
    }

    func testQueuePersistenceFailureIsReportedToDiagnostics() async {
        let engine = FakeEngine()
        let permission = FakePermissionObserver(authorization: .always)
        let lifecycle = FakeLifecycleObserver(isActive: true)
        let diagnostics = FakeDiagnosticsReporter()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let absenceScheduler = ManualPresenceExpiryScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { permission },
            lifecycleObserver: { lifecycle },
            clock: clock,
            queue: { _ in FailingQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            diagnosticsReporter: diagnostics,
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "customer-key")
        )

        sdk.start()
        engine.emit([DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55)])
        closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await waitForPersistence()

        XCTAssertEqual(diagnostics.events, [.durableQueueWriteFailed])
    }

    func testQueueFailureEmitsFailedReportState() async {
        let engine = FakeEngine()
        let permission = FakePermissionObserver(authorization: .always)
        let lifecycle = FakeLifecycleObserver(isActive: true)
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let absenceScheduler = ManualPresenceExpiryScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { permission },
            lifecycleObserver: { lifecycle },
            clock: clock,
            queue: { _ in FailingQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "customer-key")
        )
        var activityUpdates: [BeaconActivityUpdate] = []
        var reportStatusUpdates: [BeaconReportStatusUpdate] = []
        sdk.onBeaconActivityUpdated = { activityUpdates.append($0) }
        sdk.onBeaconReportStatusUpdated = { reportStatusUpdates.append($0) }

        sdk.start()
        engine.emit([DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55)])
        closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await waitForPersistence()

        XCTAssertTrue(
            activityUpdates.contains { update in
                guard case .reportFailed = update.disposition else { return false }
                return update.report?.status == .failed
            }
        )
        XCTAssertEqual(reportStatusUpdates.map { $0.report.status }, [.failed])
    }

    func testUnreadableQueueIsReportedSeparately() async {
        let engine = FakeEngine()
        let permission = FakePermissionObserver(authorization: .always)
        let lifecycle = FakeLifecycleObserver(isActive: true)
        let diagnostics = FakeDiagnosticsReporter()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let absenceScheduler = ManualPresenceExpiryScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { permission },
            lifecycleObserver: { lifecycle },
            clock: clock,
            queue: { _ in UnreadableQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            diagnosticsReporter: diagnostics,
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "customer-key")
        )

        sdk.start()
        engine.emit([DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55)])
        closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await waitForPersistence()

        XCTAssertEqual(diagnostics.events, [.durableQueueUnreadable])
    }

    func testStopFinalizePendingTracksBlockedEnqueue() async {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = makeSDK(engine: engine, queue: { _ in queue })
        var pendingValues: [Bool] = []
        let becamePending = expectation(description: "Stop finalize became pending")
        let cleared = expectation(description: "Stop finalize cleared")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            pendingValues.append(pending)
            if pending {
                becamePending.fulfill()
            } else if pendingValues.contains(true) {
                cleared.fulfill()
            }
        }

        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        sdk.stop()

        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        XCTAssertTrue(sdk.selectOpenWindowSnapshots.isEmpty)
        await fulfillment(of: [becamePending], timeout: 1)
        await queue.waitForWriteStart()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [cleared], timeout: 1)

        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true, false])
    }

    func testStopFinalizePendingSurvivesImmediateStart() async {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = makeSDK(engine: engine, queue: { _ in queue })
        let cleared = expectation(description: "Pending clears after restart write")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            if !pending {
                cleared.fulfill()
            }
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        sdk.stop()
        await queue.waitForWriteStart()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)

        sdk.start()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [cleared], timeout: 1)
        XCTAssertFalse(sdk.selectIsStopFinalizePending)
    }

    func testStopWithoutOpenWindowsDoesNotSetFinalizePending() {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let sdk = makeSDK(engine: engine, queue: { _ in queue })
        var pendingValues: [Bool] = []
        sdk.onSelectStopFinalizePendingChanged = { pendingValues.append($0) }

        sdk.start()
        sdk.stop()

        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertTrue(pendingValues.isEmpty)
    }

    func testAbsenceFinalizeDoesNotSetStopFinalizePending() async {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let absenceScheduler = ManualPresenceExpiryScheduler()
        let sdk = makeSDK(
            engine: engine,
            queue: { _ in queue },
            clock: clock,
            absenceScheduler: absenceScheduler
        )
        var pendingValues: [Bool] = []
        sdk.onSelectStopFinalizePendingChanged = { pendingValues.append($0) }

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await queue.waitForWriteStart()

        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertTrue(pendingValues.isEmpty)

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        XCTAssertFalse(sdk.selectIsStopFinalizePending)
    }

    func testStopFinalizePendingClearsOnWriteFailure() async {
        let engine = FakeEngine()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
        let absenceScheduler = ManualPresenceExpiryScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { FakeLifecycleObserver(isActive: true) },
            clock: clock,
            queue: { _ in FailingQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "customer-key")
        )
        let becamePending = expectation(description: "Pending true")
        let cleared = expectation(description: "Pending false after failure")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            if pending {
                becamePending.fulfill()
            } else {
                cleared.fulfill()
            }
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        sdk.stop()

        await fulfillment(of: [becamePending, cleared], timeout: 1)
        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(sdk.operationalStatus, .degraded(.durableQueueWriteFailed))
    }

    func testSecondStopWithoutWindowsKeepsFinalizePendingUntilCancelledWriteSettles() async {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = makeSDK(engine: engine, queue: { _ in queue })
        var pendingValues: [Bool] = []
        let cleared = expectation(description: "Pending clears after cancelled write settles")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            pendingValues.append(pending)
            if !pending {
                cleared.fulfill()
            }
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        sdk.stop()
        await queue.waitForWriteStart()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true])

        // Empty second stop must not unlock Start while the cancelled finalize
        // write is still inside the queue actor.
        sdk.stop()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true])

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [cleared], timeout: 1)
        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true, false])
    }

    func testStopFinalizePendingReplacedByOverlappingStopGeneration() async throws {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = makeSDK(engine: engine, queue: { _ in queue })
        var pendingValues: [Bool] = []
        let cleared = expectation(description: "Pending clears after replacement generation")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            pendingValues.append(pending)
            if !pending {
                cleared.fulfill()
            }
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        sdk.stop()
        await queue.waitForWriteStart()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true])

        // Immediate restart must keep the first finalize pending, then a new
        // open window + stop replaces the generation without a false blip.
        sdk.start()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 43, rssi: -60),
        ])
        sdk.stop()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true])
        XCTAssertTrue(sdk.selectOpenWindowSnapshots.isEmpty)

        await queue.waitForWriteStart()

        // Orphaned first-generation write finishes without clearing pending.
        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true])

        // Replacement generation settles and clears pending once.
        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [cleared], timeout: 1)
        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true, false])

        let queued = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(queued.map(\.minor), [42, 43])
    }

    func testClearPendingReportsEmptiesQueueWhenStopped() async throws {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let sdk = makeSDK(engine: engine, queue: { _ in queue })
        let emptied = expectation(description: "Pending snapshot emptied")
        sdk.onSelectPendingReportsChanged = { reports in
            if reports.isEmpty {
                emptied.fulfill()
            }
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        sdk.stop()
        await waitForPersistence(queue: queue)
        XCTAssertEqual(queue.records.count, 1)

        try await sdk.selectClearPendingReports()
        await fulfillment(of: [emptied], timeout: 1)
        XCTAssertTrue(queue.records.isEmpty)
        let pending = try await sdk.selectPendingReports()
        XCTAssertTrue(pending.isEmpty)
    }

    func testClearPendingReportsRefusesWhileDetectionActive() async throws {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let sdk = makeSDK(engine: engine, queue: { _ in queue })
        sdk.start()

        do {
            try await sdk.selectClearPendingReports()
            XCTFail("Expected clear to refuse while detection is active")
        } catch let error as SelectPendingReportsClearError {
            XCTAssertEqual(error, .detectionActive)
        }
    }

    func testClearPendingReportsRefusesWhileStopFinalizePending() async throws {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = makeSDK(engine: engine, queue: { _ in queue })

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        sdk.stop()
        await queue.waitForWriteStart()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)

        do {
            try await sdk.selectClearPendingReports()
            XCTFail("Expected clear to refuse while stop finalize is pending")
        } catch let error as SelectPendingReportsClearError {
            XCTAssertEqual(error, .stopFinalizePending)
        }

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
    }

    func testClearPendingReportsRecoversUnreadableQueue() async throws {
        let engine = FakeEngine()
        let queue = UnreadableQueue()
        let sdk = makeSDK(engine: engine, queue: { _ in queue })
        let clearedFinalize = expectation(description: "Stop finalize settled")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            if !pending {
                clearedFinalize.fulfill()
            }
        }

        sdk.start()
        engine.emit([
            DetectedBeacon(uuid: fleetUUID, major: 1, minor: 42, rssi: -55),
        ])
        sdk.stop()
        await fulfillment(of: [clearedFinalize], timeout: 1)

        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(sdk.operationalStatus, .degraded(.durableQueueUnreadable))

        try await sdk.selectClearPendingReports()
        XCTAssertEqual(sdk.operationalStatus, .ready)
        let pending = try await sdk.selectPendingReports()
        XCTAssertTrue(pending.isEmpty)
    }
}
