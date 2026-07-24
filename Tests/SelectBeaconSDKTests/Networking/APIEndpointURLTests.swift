import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

final class APIEndpointURLTests: XCTestCase {
    func testDerivesAuthAndIngestURLsFromBase() {
        let endpoint = APIEndpoint(baseURL: "https://api.select.example.com")
        XCTAssertEqual(
            endpoint.authURL?.absoluteString,
            "https://api.select.example.com/ingest/auth/v1"
        )
        XCTAssertEqual(
            endpoint.ingestURL?.absoluteString,
            "https://api.select.example.com/ingest/sdk/v1"
        )
        XCTAssertTrue(endpoint.isUsableHTTPBase)
    }

    func testTrimsTrailingSlashOnBase() {
        let endpoint = APIEndpoint(baseURL: "https://api.select.example.com/")
        XCTAssertEqual(
            endpoint.ingestURL?.absoluteString,
            "https://api.select.example.com/ingest/sdk/v1"
        )
    }

    func testProductionPlaceholderIsNotUsable() {
        let endpoint = APIEndpoint(baseURL: APIEndpointDefaults.production)
        XCTAssertNil(endpoint.authURL)
        XCTAssertNil(endpoint.ingestURL)
        XCTAssertFalse(endpoint.isUsableHTTPBase)
    }

    func testEnablementTokenBrokerUsesAuthPath() {
        let identity = AppIdentity(appKey: "select-app-key")!
        let configuration = SDKEnablementConfiguration(
            identity: identity,
            environment: .staging(baseURL: URL(string: "https://staging.select.example.com")!)
        )!
        let tokenConfig = configuration.tokenBrokerConfiguration()
        XCTAssertEqual(
            tokenConfig?.tokenEndpoint.absoluteString,
            "https://staging.select.example.com/ingest/auth/v1"
        )
    }
}
