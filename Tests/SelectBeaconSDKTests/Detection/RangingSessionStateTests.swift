import XCTest
import CoreLocation
@testable import SelectBeaconSDK

final class RangingSessionStateTests: XCTestCase {
    func testNotDeterminedNeverRequestsOrStartsRanging() {
        var state = RangingSessionState()
        state.configure()
        _ = state.authorizationChanged(.notDetermined)
        _ = state.applicationActivityChanged(true)

        XCTAssertEqual(state.startRequested(), .none)
    }

    func testWhenInUseStopsInBackgroundAndRestartsInForeground() {
        var state = RangingSessionState()
        state.configure()
        _ = state.authorizationChanged(.whenInUse)
        _ = state.applicationActivityChanged(true)

        XCTAssertEqual(state.startRequested(), .startRanging)
        state.didStartRanging()
        XCTAssertEqual(state.applicationActivityChanged(false), .stopRanging)
        state.didStopRanging()
        XCTAssertEqual(state.applicationActivityChanged(true), .startRanging)
    }

    func testAlwaysAuthorizationRemainsRangingInBackground() {
        var state = RangingSessionState()
        state.configure()
        _ = state.authorizationChanged(.always)
        _ = state.applicationActivityChanged(false)

        XCTAssertEqual(state.startRequested(), .startRanging)
        state.didStartRanging()
        XCTAssertEqual(state.applicationActivityChanged(false), .none)
    }
}

