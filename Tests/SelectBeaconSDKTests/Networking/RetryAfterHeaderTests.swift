import XCTest
@testable import SelectBeaconSDK

final class RetryAfterHeaderTests: XCTestCase {
    func testParsesDelaySeconds() {
        XCTAssertEqual(RetryAfterHeader.delay(from: "120"), 120)
        XCTAssertEqual(RetryAfterHeader.delay(from: " 0 "), 0)
        XCTAssertNil(RetryAfterHeader.delay(from: nil))
        XCTAssertNil(RetryAfterHeader.delay(from: ""))
        XCTAssertNil(RetryAfterHeader.delay(from: "not-a-date-or-number"))
    }

    func testParsesHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let header = "Wed, 15 Nov 2023 00:00:00 GMT"
        // 1_700_000_000 is 2023-11-14T22:13:20Z → about 1h 46m 40s until Nov 15 00:00 UTC
        let delay = RetryAfterHeader.delay(from: header, now: now)
        XCTAssertEqual(delay, 1 * 3600 + 46 * 60 + 40)
    }

    func testPastHTTPDateYieldsZero() {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let header = "Wed, 15 Nov 2023 00:00:00 GMT"
        XCTAssertEqual(RetryAfterHeader.delay(from: header, now: now), 0)
    }
}
