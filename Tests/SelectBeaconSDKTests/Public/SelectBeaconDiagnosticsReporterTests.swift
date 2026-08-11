import XCTest
@testable import SelectBeaconSDK

@MainActor
final class SelectBeaconDiagnosticsReporterTests: XCTestCase {
    func testSetDiagnosticsReporterReceivesQueueWriteFailure() async {
        let engine = FakeEngine()
        let clock = MutableClock()
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { FakeLifecycleObserver(isActive: true) },
            clock: clock,
            queue: { _ in FailingQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "customer-key", appSecret: "test-secret")
        )
        let hostReporter = FakeDiagnosticsReporter()
        sdk.setDiagnosticsReporter(hostReporter)

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        SDKTestFixture.closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await waitForEvents(hostReporter, containing: .durableQueueWriteFailed)

        XCTAssertEqual(hostReporter.events, [.durableQueueWriteFailed])
        XCTAssertEqual(sdk.operationalStatus, .degraded(.durableQueueWriteFailed))
    }

    func testClearingReporterStopsDelivery() async {
        let engine = FakeEngine()
        let clock = MutableClock()
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { FakeLifecycleObserver(isActive: true) },
            clock: clock,
            queue: { _ in FailingQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "customer-key", appSecret: "test-secret")
        )
        let first = FakeDiagnosticsReporter()
        sdk.setDiagnosticsReporter(first)

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 1)])
        SDKTestFixture.closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await waitForEvents(first, containing: .durableQueueWriteFailed)
        XCTAssertEqual(first.events, [.durableQueueWriteFailed])

        sdk.setDiagnosticsReporter(nil)
        let eventCountAfterClear = first.events.count
        engine.emit([SDKTestFixture.beacon(minor: 2)])
        SDKTestFixture.closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(first.events.count, eventCountAfterClear)
    }

    func testSwapMidSessionDeliversToNewReporter() async {
        let engine = FakeEngine()
        let clock = MutableClock()
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { FakeLifecycleObserver(isActive: true) },
            clock: clock,
            queue: { _ in FailingQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "customer-key", appSecret: "test-secret")
        )
        let first = FakeDiagnosticsReporter()
        let second = FakeDiagnosticsReporter()
        sdk.setDiagnosticsReporter(first)

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 1)])
        SDKTestFixture.closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await waitForEvents(first, containing: .durableQueueWriteFailed)

        sdk.setDiagnosticsReporter(second)
        engine.emit([SDKTestFixture.beacon(minor: 2)])
        SDKTestFixture.closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await waitForEvents(second, containing: .durableQueueWriteFailed)

        XCTAssertEqual(first.events, [.durableQueueWriteFailed])
        XCTAssertEqual(second.events, [.durableQueueWriteFailed])
    }

    private func waitForEvents(
        _ reporter: FakeDiagnosticsReporter,
        containing event: SelectBeaconDiagnosticEvent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if reporter.events.contains(event) {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(
            "Timed out waiting for diagnostic \(event); got \(reporter.events)",
            file: file,
            line: line
        )
    }
}
