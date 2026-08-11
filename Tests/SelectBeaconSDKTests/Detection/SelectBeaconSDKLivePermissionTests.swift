import XCTest
import CoreLocation
@_spi(SelectApp) @testable import SelectBeaconSDK
@testable import SelectBeaconSDKTestSupport

/// Facade coverage for the live two-manager path (`permissionObserverFactory == nil`).
@MainActor
final class SelectBeaconSDKLivePermissionTests: XCTestCase {
    func testNilPermissionFactoryUsesEngineAuthorizationAndRevocation() {
        let locationManager = FakeBeaconLocationManager()
        locationManager.authorizationStatus = .authorizedAlways
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        let lifecycle = FakeLifecycleObserver(isActive: true)
        let queue = InMemoryQueue()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: nil,
            lifecycleObserver: { lifecycle },
            clock: MutableClock(),
            queue: { _ in queue },
            locationProvider: { FakeLocationProvider() },
            networkPathObserver: { FakeNetworkPathObserver() },
            identity: AppIdentity(appKey: "customer-key", appSecret: "test-secret")
        )

        sdk.start()

        XCTAssertEqual(sdk.operationalStatus, .ranging)
        XCTAssertFalse(locationManager.startedRegions.isEmpty)

        locationManager.setAuthorization(.denied)

        XCTAssertEqual(
            sdk.operationalStatus,
            .degraded(.locationPermissionUnavailable)
        )
        XCTAssertFalse(locationManager.stoppedRegions.isEmpty)
    }

    func testLifecycleStillWiresWhenPermissionFactoryNilAndEngineIsNotObserver() {
        let engine = FakeEngine()
        let lifecycle = FakeLifecycleObserver(isActive: true)
        let queue = InMemoryQueue()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: nil,
            lifecycleObserver: { lifecycle },
            clock: MutableClock(),
            queue: { _ in queue },
            locationProvider: { FakeLocationProvider() },
            networkPathObserver: { FakeNetworkPathObserver() },
            identity: AppIdentity(appKey: "customer-key", appSecret: "test-secret")
        )

        // Expectation: auth is not wired (FakeEngine is not a PermissionObserver),
        // but lifecycle must still install so activity changes are observed.
        sdk.start()

        XCTAssertNotNil(lifecycle.onActivityChanged)

        lifecycle.setActive(false)
        lifecycle.setActive(true)

        // Without a permission observer, ranging never starts; lifecycle wiring
        // is what this test guards (previously an early return skipped it).
        XCTAssertTrue(engine.startedUUIDs.isEmpty)
    }
}
