import XCTest
import CoreLocation
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
final class CoreLocationDetectionEngineTests: XCTestCase {
    final class FakeLocationManager: LocationManaging {
        var delegate: CLLocationManagerDelegate?
        private(set) var startedConstraints: [CLBeaconIdentityConstraint] = []
        private(set) var stoppedConstraints: [CLBeaconIdentityConstraint] = []

        func startRangingBeacons(satisfying constraint: CLBeaconIdentityConstraint) {
            startedConstraints.append(constraint)
        }

        func stopRangingBeacons(satisfying constraint: CLBeaconIdentityConstraint) {
            stoppedConstraints.append(constraint)
        }
    }

    func testEngineRangesOnlyRequestedSelectConstraint() {
        let locationManager = FakeLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        let selectUUID = SDKConfiguration.default.monitoredUUIDs[0]

        engine.start(uuids: [selectUUID])

        XCTAssertEqual(locationManager.startedConstraints.count, 1)
        XCTAssertEqual(locationManager.startedConstraints.first?.uuid, selectUUID)

        engine.stop()
        XCTAssertEqual(locationManager.stoppedConstraints.map(\.uuid), [selectUUID])
    }
}
