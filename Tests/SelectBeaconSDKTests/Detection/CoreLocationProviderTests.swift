import XCTest
import CoreLocation
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
final class CoreLocationProviderTests: XCTestCase {
    final class FakeDeviceLocationManager: DeviceLocationManaging {
        var delegate: CLLocationManagerDelegate?
        var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
        var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
        var distanceFilter: CLLocationDistance = kCLDistanceFilterNone
        var allowsBackgroundLocationUpdates = false
        var pausesLocationUpdatesAutomatically = true

        private(set) var startUpdatingCount = 0
        private(set) var stopUpdatingCount = 0
        private(set) var startSignificantCount = 0
        private(set) var stopSignificantCount = 0
        private(set) var requestWhenInUseCount = 0
        private(set) var requestAlwaysCount = 0

        func startUpdatingLocation() {
            startUpdatingCount += 1
        }

        func stopUpdatingLocation() {
            stopUpdatingCount += 1
        }

        func startMonitoringSignificantLocationChanges() {
            startSignificantCount += 1
        }

        func stopMonitoringSignificantLocationChanges() {
            stopSignificantCount += 1
        }

        func emit(_ location: CLLocation) {
            (delegate as? CoreLocationProvider)?
                .locationManager(CLLocationManager(), didUpdateLocations: [location])
        }

        func emitFailure() {
            (delegate as? CoreLocationProvider)?
                .locationManager(
                    CLLocationManager(),
                    didFailWithError: NSError(domain: "test", code: 1)
                )
        }

        func setAuthorization(_ status: CLAuthorizationStatus) {
            authorizationStatus = status
            (delegate as? CoreLocationProvider)?
                .locationManagerDidChangeAuthorization(CLLocationManager())
        }
    }

    func testColdStartHasNilLocation() {
        let manager = FakeDeviceLocationManager()
        let provider = CoreLocationProvider(locationManager: manager)
        XCTAssertNil(provider.currentLocation)
    }

    func testFixOverwritesCache() {
        let manager = FakeDeviceLocationManager()
        let provider = CoreLocationProvider(locationManager: manager)
        provider.start()
        provider.setDetecting(true)

        let first = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40, longitude: -75),
            altitude: 0,
            horizontalAccuracy: 50,
            verticalAccuracy: 10,
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        let second = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 41, longitude: -76),
            altitude: 0,
            horizontalAccuracy: 40,
            verticalAccuracy: 10,
            timestamp: Date(timeIntervalSince1970: 1_100)
        )
        manager.emit(first)
        manager.emit(second)

        XCTAssertEqual(provider.currentLocation?.latitude, 41)
        XCTAssertEqual(provider.currentLocation?.longitude, -76)
        XCTAssertEqual(provider.currentLocation?.timestamp, second.timestamp)
    }

    func testDeniedClearsCacheAndStopsUpdates() {
        let manager = FakeDeviceLocationManager(authorizationStatus: .authorizedAlways)
        let provider = CoreLocationProvider(locationManager: manager)
        provider.start()
        provider.setDetecting(true)
        manager.emit(
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 40, longitude: -75),
                altitude: 0,
                horizontalAccuracy: 50,
                verticalAccuracy: 10,
                timestamp: Date()
            )
        )
        manager.setAuthorization(.denied)

        XCTAssertNil(provider.currentLocation)
        XCTAssertEqual(manager.requestWhenInUseCount, 0)
        XCTAssertEqual(manager.requestAlwaysCount, 0)
        XCTAssertGreaterThan(manager.stopUpdatingCount, 0)
    }

    func testTransientErrorRetainsCache() {
        let manager = FakeDeviceLocationManager()
        let provider = CoreLocationProvider(locationManager: manager)
        provider.start()
        provider.setDetecting(true)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40, longitude: -75),
            altitude: 0,
            horizontalAccuracy: 50,
            verticalAccuracy: 10,
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        manager.emit(location)
        manager.emitFailure()
        XCTAssertEqual(provider.currentLocation?.latitude, 40)
    }

    func testCoarseUpdatesOnlyWhileDetecting() {
        let manager = FakeDeviceLocationManager()
        let provider = CoreLocationProvider(
            configuration: SDKConfiguration.default,
            locationManager: manager
        )
        provider.start()
        XCTAssertEqual(manager.startUpdatingCount, 0)
        XCTAssertEqual(manager.startSignificantCount, 1)

        provider.setDetecting(true)
        XCTAssertEqual(manager.startUpdatingCount, 1)

        provider.setDetecting(false)
        XCTAssertEqual(manager.stopUpdatingCount, 1)
        XCTAssertEqual(manager.startSignificantCount, 1)
    }

    func testWhenInUseDoesNotStartSignificantChange() {
        let manager = FakeDeviceLocationManager(authorizationStatus: .authorizedWhenInUse)
        let provider = CoreLocationProvider(locationManager: manager)
        provider.start()
        provider.setDetecting(true)

        XCTAssertEqual(manager.startSignificantCount, 0)
        XCTAssertEqual(manager.startUpdatingCount, 1)
        XCTAssertFalse(manager.allowsBackgroundLocationUpdates)
    }

    func testSignificantChangeCanBeDisabled() {
        let configuration = SDKConfiguration.default.with(useSignificantChangeBaseline: false)
        let manager = FakeDeviceLocationManager()
        let provider = CoreLocationProvider(configuration: configuration, locationManager: manager)
        provider.start()
        XCTAssertEqual(manager.startSignificantCount, 0)
    }
}

private extension CoreLocationProviderTests.FakeDeviceLocationManager {
    convenience init(authorizationStatus: CLAuthorizationStatus) {
        self.init()
        self.authorizationStatus = authorizationStatus
    }
}
