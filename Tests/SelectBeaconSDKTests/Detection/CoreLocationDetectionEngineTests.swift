import XCTest
import CoreLocation
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
final class CoreLocationDetectionEngineTests: XCTestCase {
    private let selectUUID = SDKConfiguration.default.monitoredUUIDs[0]

    private func makeRegion(uuid: UUID = SDKConfiguration.default.monitoredUUIDs[0]) -> CLBeaconRegion {
        CLBeaconRegion(uuid: uuid, identifier: uuid.uuidString)
    }

    /// REGRESSION GUARD: ranging-only engines must fail this test.
    func testStartEstablishesRegionMonitoringNotRangingAlone() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)

        engine.start(uuids: [selectUUID])

        XCTAssertFalse(
            locationManager.startedRegions.isEmpty,
            "Engine must call startMonitoring; ranging alone cannot wake a suspended app"
        )
        XCTAssertEqual(locationManager.monitoredBeaconUUIDs, [selectUUID])
        XCTAssertTrue(locationManager.startedRegions.contains { $0 is CLBeaconRegion })
        XCTAssertEqual(locationManager.requestedStateRegions.count, 1)
    }

    func testEngineRangesRequestedSelectConstraintInForeground() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)

        engine.start(uuids: [selectUUID])

        XCTAssertEqual(locationManager.startedConstraints.count, 1)
        XCTAssertEqual(locationManager.startedConstraints.first?.uuid, selectUUID)

        engine.stop()
        XCTAssertEqual(locationManager.stoppedConstraints.map(\.uuid), [selectUUID])
        XCTAssertEqual(locationManager.stoppedRegions.count, 1)
        XCTAssertEqual(
            (locationManager.stoppedRegions.first as? CLBeaconRegion)?.uuid,
            selectUUID
        )
    }

    func testBackgroundStartDoesNotBeginContinuousRanging() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        engine.setApplicationActive(false)

        engine.start(uuids: [selectUUID])

        XCTAssertEqual(locationManager.startedRegions.count, 1)
        XCTAssertTrue(locationManager.startedConstraints.isEmpty)
    }

    func testDidEnterRegionStartsRanging() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        engine.setApplicationActive(false)
        engine.start(uuids: [selectUUID])
        XCTAssertTrue(locationManager.startedConstraints.isEmpty)

        engine.locationManager(CLLocationManager(), didEnterRegion: makeRegion())

        XCTAssertEqual(locationManager.startedConstraints.map(\.uuid), [selectUUID])
    }

    func testDidExitRegionStopsRanging() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        engine.setApplicationActive(false)
        engine.start(uuids: [selectUUID])
        engine.locationManager(CLLocationManager(), didEnterRegion: makeRegion())
        XCTAssertEqual(locationManager.startedConstraints.count, 1)

        engine.locationManager(CLLocationManager(), didExitRegion: makeRegion())

        XCTAssertEqual(locationManager.stoppedConstraints.map(\.uuid), [selectUUID])
    }

    func testDidDetermineStateInsideStartsRanging() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        engine.setApplicationActive(false)
        engine.start(uuids: [selectUUID])

        engine.locationManager(
            CLLocationManager(),
            didDetermineState: .inside,
            for: makeRegion()
        )

        XCTAssertEqual(locationManager.startedConstraints.map(\.uuid), [selectUUID])
    }

    func testDidDetermineStateOutsideDoesNotStartRanging() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        engine.setApplicationActive(false)
        engine.start(uuids: [selectUUID])

        engine.locationManager(
            CLLocationManager(),
            didDetermineState: .outside,
            for: makeRegion()
        )

        XCTAssertTrue(locationManager.startedConstraints.isEmpty)
        XCTAssertTrue(locationManager.stoppedConstraints.isEmpty)
    }

    func testDidDetermineStateOutsideStopsActiveRanging() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        engine.setApplicationActive(false)
        engine.start(uuids: [selectUUID])
        engine.locationManager(
            CLLocationManager(),
            didDetermineState: .inside,
            for: makeRegion()
        )

        engine.locationManager(
            CLLocationManager(),
            didDetermineState: .outside,
            for: makeRegion()
        )

        XCTAssertEqual(locationManager.stoppedConstraints.map(\.uuid), [selectUUID])
    }

    func testStopRemovesAllMonitoredRegions() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        let second = UUID()
        engine.start(uuids: [selectUUID, second])

        engine.stop()

        XCTAssertEqual(locationManager.stoppedRegions.count, 2)
        let stoppedUUIDs = Set(locationManager.stoppedRegions.compactMap { ($0 as? CLBeaconRegion)?.uuid })
        XCTAssertEqual(stoppedUUIDs, Set([selectUUID, second]))
    }

    func testSetApplicationActiveFalseStopsRangingButKeepsMonitoring() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        engine.start(uuids: [selectUUID])
        XCTAssertEqual(locationManager.startedConstraints.count, 1)
        let monitoredBefore = locationManager.startedRegions.count

        engine.setApplicationActive(false)

        XCTAssertEqual(locationManager.stoppedConstraints.map(\.uuid), [selectUUID])
        XCTAssertEqual(locationManager.startedRegions.count, monitoredBefore)
        XCTAssertTrue(locationManager.stoppedRegions.isEmpty)
    }

    func testSetApplicationActiveTrueRestartsRanging() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        engine.start(uuids: [selectUUID])
        engine.setApplicationActive(false)
        locationManager.clearRangingLog()

        engine.setApplicationActive(true)

        XCTAssertEqual(locationManager.startedConstraints.map(\.uuid), [selectUUID])
    }

    func testMonitoredRegionCountRespectsBudgetCap() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        let many = (0..<CoreLocationDetectionEngine.maxMonitoredBeaconUUIDs + 3).map { _ in UUID() }

        engine.start(uuids: many)

        XCTAssertEqual(
            locationManager.startedRegions.count,
            CoreLocationDetectionEngine.maxMonitoredBeaconUUIDs
        )
        XCTAssertLessThanOrEqual(
            locationManager.startedRegions.count,
            CoreLocationDetectionEngine.maxMonitoredBeaconUUIDs
        )
    }

    func testAuthorizationReflectsLocationManagerStatus() {
        let locationManager = FakeBeaconLocationManager()
        locationManager.authorizationStatus = .authorizedWhenInUse
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)

        XCTAssertEqual(engine.authorization, .whenInUse)
    }

    func testAuthorizationChangeNotifiesObserver() {
        let locationManager = FakeBeaconLocationManager()
        let engine = CoreLocationDetectionEngine(locationManager: locationManager)
        var seen: [LocationAuthorization] = []
        engine.onAuthorizationChanged = { seen.append($0) }

        locationManager.setAuthorization(.denied)

        XCTAssertEqual(seen, [.unavailable])
        XCTAssertEqual(engine.authorization, .unavailable)
    }
}
