import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

final class ActiveBeaconStoreTests: XCTestCase {
    private let uuid = UUID(uuidString: "76F87C5C-AB0C-45C5-8E9A-19DEF7DC2911")!
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testRecordReplacesPriorObservationForSameBeacon() {
        var store = ActiveBeaconStore()
        store.record(observation(rssi: -70, at: now))
        store.record(observation(rssi: -55, at: now.addingTimeInterval(1)))

        XCTAssertEqual(store.snapshot.count, 1)
        XCTAssertEqual(store.snapshot.first?.rssi, -55)
    }

    func testExpireRemovesOnlyObservationsBeforeCutoff() {
        var store = ActiveBeaconStore()
        store.record(observation(rssi: -70, at: now.addingTimeInterval(-31)))
        store.record(
            BeaconObservation(
                uuid: uuid,
                major: 1,
                minor: 43,
                rssi: -60,
                observedAt: now.addingTimeInterval(-29)
            )
        )

        XCTAssertTrue(store.expire(before: now.addingTimeInterval(-30)))
        XCTAssertEqual(store.snapshot.map(\.minor), [43])
    }

    private func observation(rssi: Int, at date: Date) -> BeaconObservation {
        BeaconObservation(
            uuid: uuid,
            major: 1,
            minor: 42,
            rssi: rssi,
            observedAt: date
        )
    }
}
