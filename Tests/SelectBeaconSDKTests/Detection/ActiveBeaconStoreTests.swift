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

    func testSnapshotOrdersByUUIDThenMajorThenMinor() {
        var store = ActiveBeaconStore()
        let otherUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        store.record(
            BeaconObservation(uuid: uuid, major: 2, minor: 9, rssi: -50, observedAt: now)
        )
        store.record(
            BeaconObservation(uuid: otherUUID, major: 1, minor: 1, rssi: -60, observedAt: now)
        )
        store.record(
            BeaconObservation(uuid: uuid, major: 1, minor: 5, rssi: -55, observedAt: now)
        )
        store.record(
            BeaconObservation(uuid: uuid, major: 1, minor: 2, rssi: -40, observedAt: now)
        )

        let snapshot = store.snapshot
        XCTAssertEqual(
            snapshot.map { "\($0.uuid.uuidString)-\($0.major)-\($0.minor)" },
            [
                "\(uuid.uuidString)-1-2",
                "\(uuid.uuidString)-1-5",
                "\(uuid.uuidString)-2-9",
                "\(otherUUID.uuidString)-1-1",
            ]
        )

        store.record(
            BeaconObservation(uuid: uuid, major: 1, minor: 2, rssi: -10, observedAt: now.addingTimeInterval(1))
        )
        XCTAssertEqual(store.snapshot.map(\.minor), [2, 5, 9, 1])
        XCTAssertEqual(store.snapshot.first(where: { $0.minor == 2 })?.rssi, -10)
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
