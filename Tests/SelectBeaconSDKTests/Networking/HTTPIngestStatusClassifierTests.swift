import XCTest
@testable import SelectBeaconSDK

final class HTTPIngestStatusClassifierTests: XCTestCase {
    func testClassifiesStatusMatrix() {
        XCTAssertEqual(
            HTTPIngestStatusClassifier.classify(statusCode: 200, retryAfterHeader: nil),
            .success
        )
        XCTAssertEqual(
            HTTPIngestStatusClassifier.classify(statusCode: 429, retryAfterHeader: "30"),
            .rateLimited(retryAfter: 30)
        )
        XCTAssertEqual(
            HTTPIngestStatusClassifier.classify(statusCode: 429, retryAfterHeader: nil),
            .rateLimited(retryAfter: nil)
        )
        XCTAssertEqual(
            HTTPIngestStatusClassifier.classify(statusCode: 401, retryAfterHeader: nil),
            .unauthorized(statusCode: 401)
        )
        XCTAssertEqual(
            HTTPIngestStatusClassifier.classify(statusCode: 403, retryAfterHeader: nil),
            .unauthorized(statusCode: 403)
        )
        XCTAssertEqual(
            HTTPIngestStatusClassifier.classify(statusCode: 422, retryAfterHeader: nil),
            .clientError(statusCode: 422)
        )
        XCTAssertEqual(
            HTTPIngestStatusClassifier.classify(statusCode: 503, retryAfterHeader: nil),
            .serverError(statusCode: 503)
        )
    }
}
