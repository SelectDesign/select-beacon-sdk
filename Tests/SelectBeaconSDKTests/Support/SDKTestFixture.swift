import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
enum SDKTestFixture {
    static let fleetUUID = SDKConfiguration.default.monitoredUUIDs[0]

    static func makeSDK(
        authorization: LocationAuthorization = .always,
        isActive: Bool = true,
        identity: AppIdentity? = AppIdentity(appKey: "customer-key"),
        environment: SelectBeaconSDK.Environment = .production,
        locationProvider: FakeLocationProvider = FakeLocationProvider(),
        clock: MutableClock = MutableClock(),
        absenceScheduler: ManualDelayedActionScheduler = ManualDelayedActionScheduler()
    ) -> (
        sdk: SelectBeaconSDK,
        engine: FakeEngine,
        permission: FakePermissionObserver,
        lifecycle: FakeLifecycleObserver,
        queue: InMemoryQueue,
        locationProvider: FakeLocationProvider,
        clock: MutableClock,
        absenceScheduler: ManualDelayedActionScheduler
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

    static func makeSDK(
        engine: FakeEngine,
        queue: @escaping (String) -> any DurableDetectionQueue,
        lifecycle: FakeLifecycleObserver = FakeLifecycleObserver(isActive: true),
        clock: MutableClock = MutableClock(),
        absenceScheduler: ManualDelayedActionScheduler = ManualDelayedActionScheduler()
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

    static func closeOpenWindows(
        clock: MutableClock,
        absenceScheduler: ManualDelayedActionScheduler
    ) {
        clock.now = clock.now.addingTimeInterval(SDKConfiguration.default.absenceTimeout + 0.1)
        absenceScheduler.fire()
    }

    static func waitForQueueCount(
        _ queue: InMemoryQueue,
        minCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if queue.records.count >= minCount {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(
            "Timed out waiting for queue count >= \(minCount); got \(queue.records.count)",
            file: file,
            line: line
        )
    }

    static func testURL(_ string: String, file: StaticString = #filePath, line: UInt = #line) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Invalid test URL: \(string)", file: file, line: line)
            return URL(fileURLWithPath: "/invalid-test-url")
        }
        return url
    }

    static func beacon(minor: Int, rssi: Int = -55) -> DetectedBeacon {
        DetectedBeacon(uuid: fleetUUID, major: 1, minor: minor, rssi: rssi)
    }
}
