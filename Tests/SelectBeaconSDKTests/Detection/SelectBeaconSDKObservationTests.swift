import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
final class SelectBeaconSDKObservationTests: XCTestCase {
    func testStopAndStartBeginsNewWindowSession() async {
        let fixture = SDKTestFixture.makeSDK()
        let beacon = SDKTestFixture.beacon(minor: 42)

        fixture.sdk.start()
        fixture.engine.emit([beacon])
        fixture.sdk.stop()
        await SDKTestFixture.waitForQueueCount(fixture.queue, minCount: 1)

        fixture.sdk.start()
        fixture.engine.emit([beacon])
        fixture.sdk.stop()
        await SDKTestFixture.waitForQueueCount(fixture.queue, minCount: 2)

        XCTAssertEqual(fixture.queue.records.count, 2)
        XCTAssertEqual(fixture.queue.records.map(\.minor), [42, 42])
    }

    func testWindowCloseEnqueuesBeforePendingCallback() async {
        let fixture = SDKTestFixture.makeSDK()
        fixture.sdk.start()
        let beacon = SDKTestFixture.beacon(minor: 42)
        var queueCountDuringCallback = 0
        let pending = expectation(description: "Pending reports updated")
        fixture.sdk.onSelectPendingReportsChanged = { _ in
            queueCountDuringCallback = fixture.queue.records.count
            pending.fulfill()
        }

        fixture.engine.emit([beacon])
        XCTAssertTrue(fixture.queue.records.isEmpty)
        XCTAssertEqual(fixture.sdk.selectOpenWindowSnapshots.map(\.minor), [42])

        SDKTestFixture.closeOpenWindows(
            clock: fixture.clock,
            absenceScheduler: fixture.absenceScheduler
        )
        await fulfillment(of: [pending], timeout: 1)

        XCTAssertEqual(queueCountDuringCallback, 1)
        XCTAssertEqual(fixture.queue.records.count, 1)
        XCTAssertEqual(fixture.queue.records.first?.observationCount, 1)
        XCTAssertTrue(fixture.sdk.selectOpenWindowSnapshots.isEmpty)
    }

    func testInWindowSightingsAggregateIntoOneReport() async {
        let fixture = SDKTestFixture.makeSDK()
        fixture.sdk.start()

        fixture.engine.emit([SDKTestFixture.beacon(minor: 42, rssi: -55)])
        fixture.engine.emit([SDKTestFixture.beacon(minor: 42, rssi: -70)])
        XCTAssertEqual(fixture.sdk.selectOpenWindowSnapshots.first?.observationCount, 2)
        XCTAssertEqual(fixture.sdk.selectOpenWindowSnapshots.first?.bestRSSI, -55)

        SDKTestFixture.closeOpenWindows(
            clock: fixture.clock,
            absenceScheduler: fixture.absenceScheduler
        )
        await SDKTestFixture.waitForQueueCount(fixture.queue, minCount: 1)

        XCTAssertEqual(fixture.queue.records.count, 1)
        XCTAssertEqual(fixture.queue.records.first?.observationCount, 2)
        XCTAssertEqual(fixture.queue.records.first?.bestRSSI, -55)
    }

    func testSelectSPIProvidesActiveAndPendingSnapshots() async throws {
        let fixture = SDKTestFixture.makeSDK()
        fixture.sdk.start()
        fixture.engine.emit([
            SDKTestFixture.beacon(minor: 1),
            SDKTestFixture.beacon(minor: 2, rssi: -60),
        ])
        SDKTestFixture.closeOpenWindows(
            clock: fixture.clock,
            absenceScheduler: fixture.absenceScheduler
        )
        await SDKTestFixture.waitForQueueCount(fixture.queue, minCount: 2)

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
        let fixture = SDKTestFixture.makeSDK(locationProvider: locationProvider)
        fixture.sdk.start()
        fixture.engine.emit([SDKTestFixture.beacon(minor: 42)])
        SDKTestFixture.closeOpenWindows(
            clock: fixture.clock,
            absenceScheduler: fixture.absenceScheduler
        )
        await SDKTestFixture.waitForQueueCount(fixture.queue, minCount: 1)

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
        let fixture = SDKTestFixture.makeSDK(locationProvider: locationProvider)
        fixture.sdk.start()
        fixture.engine.emit([SDKTestFixture.beacon(minor: 42)])
        SDKTestFixture.closeOpenWindows(
            clock: fixture.clock,
            absenceScheduler: fixture.absenceScheduler
        )
        await SDKTestFixture.waitForQueueCount(fixture.queue, minCount: 1)

        XCTAssertEqual(fixture.queue.records.first?.location?.latitude, 40.7)
        XCTAssertEqual(fixture.locationProvider.startCount, 1)
        XCTAssertTrue(fixture.locationProvider.isDetecting)
    }

    func testActiveBeaconExpiresAfterAbsenceTimeout() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let engine = FakeEngine()
        let clock = MutableClock(now: now)
        let expiryScheduler = ManualDelayedActionScheduler()
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
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        XCTAssertEqual(sdk.selectActiveBeaconObservations.map(\.minor), [42])

        clock.now = now.addingTimeInterval(SDKConfiguration.default.absenceTimeout)
        expiryScheduler.fire()

        XCTAssertTrue(sdk.selectActiveBeaconObservations.isEmpty)
    }

    func testStopDuringWriteSuppressesPendingNotify() async {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let clock = MutableClock()
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SDKTestFixture.makeSDK(
            engine: engine,
            queue: { _ in queue },
            clock: clock,
            absenceScheduler: absenceScheduler
        )
        let callback = expectation(description: "No pending callback after stop")
        callback.isInverted = true
        sdk.onSelectPendingReportsChanged = { _ in callback.fulfill() }

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        SDKTestFixture.closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await queue.waitForWriteStart()

        sdk.stop()
        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [callback], timeout: 0.1)

        let queued = try? await queue.nextBatch(limit: 10)
        XCTAssertEqual(queued?.map(\.minor), [42])
    }

    func testPausedRangingDeliversCompletedPendingReportUpdate() async {
        let engine = FakeEngine()
        let permission = FakePermissionObserver(authorization: .whenInUse)
        let lifecycle = FakeLifecycleObserver(isActive: true)
        let queue = BlockingQueue()
        let clock = MutableClock()
        let absenceScheduler = ManualDelayedActionScheduler()
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
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        SDKTestFixture.closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await queue.waitForWriteStart()

        lifecycle.setActive(false)
        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [update], timeout: 1)
    }

    func testStopAndStartDoesNotDeliverOldSessionCallback() async {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let clock = MutableClock()
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SDKTestFixture.makeSDK(
            engine: engine,
            queue: { _ in queue },
            clock: clock,
            absenceScheduler: absenceScheduler
        )
        var callbackMinors: [[Int]] = []
        let staleSuppressed = expectation(description: "Old session pending suppressed")
        staleSuppressed.isInverted = true
        let newSession = expectation(description: "New session pending callback")
        var expectingNewSession = false
        sdk.onSelectPendingReportsChanged = { reports in
            callbackMinors.append(reports.map(\.minor))
            if expectingNewSession {
                newSession.fulfill()
            } else {
                staleSuppressed.fulfill()
            }
        }

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 1)])
        SDKTestFixture.closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await queue.waitForWriteStart()

        sdk.stop()
        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 2)])
        SDKTestFixture.closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [staleSuppressed], timeout: 0.1)

        expectingNewSession = true
        await queue.waitForWriteStart()
        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [newSession], timeout: 1)

        XCTAssertEqual(callbackMinors.count, 1)
        XCTAssertEqual(Set(callbackMinors[0]), Set([1, 2]))
    }

    func testRangingBatchesPreserveQueueOrder() async {
        let fixture = SDKTestFixture.makeSDK()

        fixture.sdk.start()
        fixture.engine.emit([
            SDKTestFixture.beacon(minor: 1),
            SDKTestFixture.beacon(minor: 2),
        ])
        fixture.engine.emit([SDKTestFixture.beacon(minor: 3)])
        SDKTestFixture.closeOpenWindows(
            clock: fixture.clock,
            absenceScheduler: fixture.absenceScheduler
        )
        await SDKTestFixture.waitForQueueCount(fixture.queue, minCount: 3)

        XCTAssertEqual(fixture.queue.records.map(\.minor), [1, 2, 3])
    }

    func testUnknownRSSIIsIgnored() async {
        let fixture = SDKTestFixture.makeSDK()
        fixture.sdk.start()

        fixture.engine.emit([DetectedBeacon(
            uuid: SDKTestFixture.fleetUUID,
            major: 1,
            minor: 42,
            rssi: 0
        )])
        SDKTestFixture.closeOpenWindows(
            clock: fixture.clock,
            absenceScheduler: fixture.absenceScheduler
        )
        await Task.yield()

        XCTAssertTrue(fixture.sdk.selectActiveBeaconObservations.isEmpty)
        XCTAssertTrue(fixture.sdk.selectOpenWindowSnapshots.isEmpty)
        XCTAssertTrue(fixture.queue.records.isEmpty)
    }

    func testQueuePersistenceFailureIsReportedToDiagnostics() async {
        let engine = FakeEngine()
        let diagnostics = FakeDiagnosticsReporter()
        let clock = MutableClock()
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { FakeLifecycleObserver(isActive: true) },
            clock: clock,
            queue: { _ in FailingQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            diagnosticsReporter: diagnostics,
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "customer-key")
        )

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        SDKTestFixture.closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await waitForDiagnostics(diagnostics, event: .durableQueueWriteFailed)

        XCTAssertEqual(diagnostics.events, [.durableQueueWriteFailed])
        XCTAssertEqual(sdk.operationalStatus, .degraded(.durableQueueWriteFailed))
    }

    func testUnreadableQueueIsReportedSeparately() async {
        let engine = FakeEngine()
        let diagnostics = FakeDiagnosticsReporter()
        let clock = MutableClock()
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { FakeLifecycleObserver(isActive: true) },
            clock: clock,
            queue: { _ in UnreadableQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            diagnosticsReporter: diagnostics,
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "customer-key")
        )

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        SDKTestFixture.closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await waitForDiagnostics(diagnostics, event: .durableQueueUnreadable)

        XCTAssertTrue(diagnostics.events.contains(.durableQueueUnreadable))
        XCTAssertTrue(diagnostics.events.allSatisfy { $0 == .durableQueueUnreadable })
        XCTAssertEqual(sdk.operationalStatus, .degraded(.durableQueueUnreadable))
    }

    private func waitForDiagnostics(
        _ diagnostics: FakeDiagnosticsReporter,
        event: DiagnosticEvent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if diagnostics.events.contains(event) {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(
            "Timed out waiting for diagnostic \(event); got \(diagnostics.events)",
            file: file,
            line: line
        )
    }
}
