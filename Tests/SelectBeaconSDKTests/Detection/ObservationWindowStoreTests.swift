import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

final class ObservationWindowStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let fleetUUID = SDKConfiguration.default.monitoredUUIDs[0]

    private func makeStore() -> ObservationWindowStore {
        ObservationWindowStore(
            windowDuration: SDKConfiguration.default.windowDuration,
            absenceTimeout: SDKConfiguration.default.absenceTimeout
        )
    }

    private func sighting(rssi: Int) -> BeaconSighting {
        BeaconSighting(uuid: fleetUUID, major: 1, minor: 42, rssi: rssi)
    }

    func testFirstSightingOpensWindow() {
        var store = makeStore()
        let effect = store.process(sighting: sighting(rssi: -70), location: nil, now: t0)
        XCTAssertEqual(effect, .updated)
        XCTAssertTrue(store.hasOpenWindows)
    }

    func testInWindowUpdatesAggregateWithoutClosing() {
        var store = makeStore()
        _ = store.process(sighting: sighting(rssi: -70), location: nil, now: t0)
        let later = LocationFix(
            latitude: 40.1,
            longitude: -75.1,
            horizontalAccuracy: 65,
            timestamp: t0.addingTimeInterval(10)
        )
        let effect = store.process(
            sighting: sighting(rssi: -60),
            location: later,
            now: t0.addingTimeInterval(10)
        )
        XCTAssertEqual(effect, .updated)

        let closed = store.finalizeAllOpenWindows()
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].bestRSSI, -60)
        XCTAssertEqual(closed[0].observationCount, 2)
        XCTAssertEqual(closed[0].location, later)
        XCTAssertEqual(closed[0].latestTimestamp, t0.addingTimeInterval(10))
    }

    func testBestRSSIKeepsMaximumWhenLaterSightingIsWeaker() {
        var store = makeStore()
        _ = store.process(sighting: sighting(rssi: -55), location: nil, now: t0)
        _ = store.process(sighting: sighting(rssi: -70), location: nil, now: t0.addingTimeInterval(5))
        let closed = store.finalizeAllOpenWindows()
        XCTAssertEqual(closed[0].bestRSSI, -55)
        XCTAssertEqual(closed[0].observationCount, 2)
    }

    func testLocationUsesMostRecentNonNilFixIndependentOfBestRSSI() {
        var store = makeStore()
        let earlyLocation = LocationFix(
            latitude: 40.0,
            longitude: -75.0,
            horizontalAccuracy: 80,
            timestamp: t0
        )
        let laterLocation = LocationFix(
            latitude: 40.2,
            longitude: -75.2,
            horizontalAccuracy: 90,
            timestamp: t0.addingTimeInterval(20)
        )
        _ = store.process(sighting: sighting(rssi: -50), location: earlyLocation, now: t0)
        _ = store.process(
            sighting: sighting(rssi: -70),
            location: laterLocation,
            now: t0.addingTimeInterval(20)
        )
        let closed = store.finalizeAllOpenWindows()
        XCTAssertEqual(closed[0].bestRSSI, -50)
        XCTAssertEqual(closed[0].location, laterLocation)
    }

    func testSightingAfterWindowDurationClosesAndOpensReplacement() {
        var store = makeStore()
        _ = store.process(sighting: sighting(rssi: -70), location: nil, now: t0)
        let effect = store.process(
            sighting: sighting(rssi: -65),
            location: nil,
            now: t0.addingTimeInterval(60.1)
        )
        guard case .closed(let first, let openedReplacement) = effect else {
            return XCTFail("Expected closed effect")
        }
        XCTAssertTrue(openedReplacement)
        XCTAssertEqual(first.observationCount, 1)
        XCTAssertEqual(first.bestRSSI, -70)

        let second = store.finalizeAllOpenWindows()
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].bestRSSI, -65)
        XCTAssertEqual(second[0].windowStartedAt, t0.addingTimeInterval(60.1))
    }

    func testAbsenceClosesWindowWithoutFurtherSightings() {
        var store = makeStore()
        _ = store.process(sighting: sighting(rssi: -70), location: nil, now: t0)
        let closed = store.expireAbsences(now: t0.addingTimeInterval(30.1))
        XCTAssertEqual(closed.count, 1)
        XCTAssertFalse(store.hasOpenWindows)
    }

    func testNilLocationIsPreserved() {
        var store = makeStore()
        _ = store.process(sighting: sighting(rssi: -70), location: nil, now: t0)
        let closed = store.finalizeAllOpenWindows()
        XCTAssertNil(closed[0].location)
    }

    func testSnapshotReflectsOpenWindowAggregates() {
        var store = makeStore()
        _ = store.process(sighting: sighting(rssi: -70), location: nil, now: t0)
        _ = store.process(
            sighting: sighting(rssi: -50),
            location: LocationFix(
                latitude: 1,
                longitude: 2,
                horizontalAccuracy: 50,
                timestamp: t0.addingTimeInterval(5)
            ),
            now: t0.addingTimeInterval(5)
        )
        let snapshot = store.snapshot
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].bestRSSI, -50)
        XCTAssertEqual(snapshot[0].observationCount, 2)
        XCTAssertEqual(snapshot[0].location?.latitude, 1)
        _ = store.finalizeAllOpenWindows()
        XCTAssertTrue(store.snapshot.isEmpty)
    }
}
