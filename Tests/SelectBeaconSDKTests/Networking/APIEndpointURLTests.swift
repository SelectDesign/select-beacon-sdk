import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

final class APIEndpointURLTests: XCTestCase {
    func testDerivesAuthAndIngestURLsFromBase() {
        let endpoint = APIEndpoint(baseURL: "https://api.select.example.com")
        XCTAssertEqual(
            endpoint.authURL?.absoluteString,
            "https://api.select.example.com/auth/v1"
        )
        XCTAssertEqual(
            endpoint.ingestURL?.absoluteString,
            "https://api.select.example.com/sdk/v1/detections"
        )
        XCTAssertTrue(endpoint.isUsableHTTPBase)
    }

    func testTrimsTrailingSlashOnBase() {
        let endpoint = APIEndpoint(baseURL: "https://api.select.example.com/")
        XCTAssertEqual(
            endpoint.ingestURL?.absoluteString,
            "https://api.select.example.com/sdk/v1/detections"
        )
    }

    func testProductionEndpointDerivesAuthAndIngestURLs() {
        let endpoint = APIEndpoint(baseURL: APIEndpointDefaults.production)
        XCTAssertEqual(
            endpoint.authURL?.absoluteString,
            "https://ingestor.beacons.selectbrandhub.com/auth/v1"
        )
        XCTAssertEqual(
            endpoint.ingestURL?.absoluteString,
            "https://ingestor.beacons.selectbrandhub.com/sdk/v1/detections"
        )
        XCTAssertTrue(endpoint.isUsableHTTPBase)
    }

    func testProductionEnvironmentEnablesTokenBroker() {
        let identity = AppIdentity(appKey: "select-app-key", appSecret: "test-secret")!
        let configuration = SDKEnablementConfiguration(
            identity: identity,
            environment: .production
        )!
        let tokenConfig = configuration.tokenBrokerConfiguration()
        XCTAssertEqual(
            tokenConfig?.tokenEndpoint.absoluteString,
            "https://ingestor.beacons.selectbrandhub.com/auth/v1"
        )
    }

    func testEnablementTokenBrokerUsesAuthPath() {
        let identity = AppIdentity(appKey: "select-app-key", appSecret: "test-secret")!
        let configuration = SDKEnablementConfiguration(
            identity: identity,
            environment: .staging(baseURL: URL(string: "https://staging.select.example.com")!)
        )!
        let tokenConfig = configuration.tokenBrokerConfiguration()
        XCTAssertEqual(
            tokenConfig?.tokenEndpoint.absoluteString,
            "https://staging.select.example.com/auth/v1"
        )
        XCTAssertEqual(tokenConfig?.appKey, "select-app-key")
        XCTAssertEqual(tokenConfig?.appSecret, "test-secret")
    }

    func testCleartextHTTPBaseIsNotUsable() {
        let endpoint = APIEndpoint(baseURL: "http://staging.select.example.com")
        XCTAssertNil(endpoint.authURL)
        XCTAssertNil(endpoint.ingestURL)
        XCTAssertFalse(endpoint.isUsableHTTPBase)
    }

    func testCleartextHTTPStagingEnvironmentDoesNotEnable() {
        let identity = AppIdentity(appKey: "select-app-key", appSecret: "test-secret")!
        let configuration = SDKEnablementConfiguration(
            identity: identity,
            environment: .staging(baseURL: URL(string: "http://staging.select.example.com")!)
        )
        XCTAssertNil(configuration)
    }
}
