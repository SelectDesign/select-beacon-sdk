import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK
@testable import SelectBeaconSDKTestSupport

@MainActor
final class HTTPIngestUploadTransportTests: XCTestCase {
    private final class FakeHTTPDataLoader: HTTPDataLoading, @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        var statusCode = 200
        var headerFields: [String: String]?
        var shouldFailNetwork = false

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            if shouldFailNetwork {
                throw URLError(.notConnectedToInternet)
            }
            let response = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headerFields
            )!
            return (Data(), response)
        }
    }

    private let fleetUUID = SDKConfiguration.default.monitoredUUIDs[0]
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDetection(minor: Int) -> QueuedDetection {
        QueuedDetection(
            uuid: fleetUUID,
            major: 1,
            minor: minor,
            bestRSSI: -55,
            latestTimestamp: t0,
            windowStartedAt: t0,
            observationCount: 1,
            location: nil,
            queuedAt: t0
        )
    }

    func testSuccessfulUploadAcknowledgesEntireBatch() async throws {
        let client = FakeHTTPDataLoader()
        let detections = [makeDetection(minor: 1), makeDetection(minor: 2)]
        let transport = HTTPIngestUploadTransport(
            ingestURL: URL(string: "https://api.select.example.com/sdk/v1/detections")!,
            httpClient: client,
            deviceIdentifier: FakeDeviceIdentifier()
        )

        let response = try await transport.upload(
            detections: detections,
            authorization: UploadAuthorization(accessToken: "token-abc")
        )

        XCTAssertEqual(response, .accepted(acknowledgedIDs: detections.map(\.id)))
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer token-abc"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            HTTPIngestUploadTransport.jsonContentType
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            HTTPIngestUploadTransport.jsonContentType
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let items = try XCTUnwrap(json["detections"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items.first?["type"])
        XCTAssertNil(items.first?["attributes"])
        XCTAssertEqual(items.first?["minor"] as? Int, 1)
        XCTAssertEqual(items.first?["idempotency_key"] as? String, detections[0].id.uuidString)
    }

    func testNon200Throws() async {
        let client = FakeHTTPDataLoader()
        client.statusCode = 500
        let transport = HTTPIngestUploadTransport(
            ingestURL: URL(string: "https://api.select.example.com/sdk/v1/detections")!,
            httpClient: client,
            deviceIdentifier: FakeDeviceIdentifier()
        )

        do {
            _ = try await transport.upload(
                detections: [makeDetection(minor: 1)],
                authorization: UploadAuthorization(accessToken: "token")
            )
            XCTFail("Expected failure")
        } catch let error as HTTPIngestUploadError {
            XCTAssertEqual(error, .serverError(statusCode: 500))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRetryAfterHeaderThrowsRateLimited() async {
        let client = FakeHTTPDataLoader()
        client.statusCode = 429
        client.headerFields = ["Retry-After": "90"]
        let transport = HTTPIngestUploadTransport(
            ingestURL: URL(string: "https://api.select.example.com/sdk/v1/detections")!,
            httpClient: client,
            deviceIdentifier: FakeDeviceIdentifier()
        )

        do {
            _ = try await transport.upload(
                detections: [makeDetection(minor: 1)],
                authorization: UploadAuthorization(accessToken: "token")
            )
            XCTFail("Expected rate limit failure")
        } catch let error as HTTPIngestUploadError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 90))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test429WithoutRetryAfterStillRateLimited() async {
        let client = FakeHTTPDataLoader()
        client.statusCode = 429
        let transport = HTTPIngestUploadTransport(
            ingestURL: URL(string: "https://api.select.example.com/sdk/v1/detections")!,
            httpClient: client,
            deviceIdentifier: FakeDeviceIdentifier()
        )

        do {
            _ = try await transport.upload(
                detections: [makeDetection(minor: 1)],
                authorization: UploadAuthorization(accessToken: "token")
            )
            XCTFail("Expected rate limit failure")
        } catch let error as HTTPIngestUploadError {
            XCTAssertEqual(error, .rateLimited(retryAfter: nil))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test400ThrowsClientError() async {
        let client = FakeHTTPDataLoader()
        client.statusCode = 400
        let transport = HTTPIngestUploadTransport(
            ingestURL: URL(string: "https://api.select.example.com/sdk/v1/detections")!,
            httpClient: client,
            deviceIdentifier: FakeDeviceIdentifier()
        )

        do {
            _ = try await transport.upload(
                detections: [makeDetection(minor: 1)],
                authorization: UploadAuthorization(accessToken: "token")
            )
            XCTFail("Expected client error")
        } catch let error as HTTPIngestUploadError {
            XCTAssertEqual(error, .clientError(statusCode: 400))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingDeviceIdThrowsBeforeNetwork() async {
        let client = FakeHTTPDataLoader()
        let transport = HTTPIngestUploadTransport(
            ingestURL: URL(string: "https://api.select.example.com/sdk/v1/detections")!,
            httpClient: client,
            deviceIdentifier: FakeDeviceIdentifier(deviceId: nil)
        )

        do {
            _ = try await transport.upload(
                detections: [makeDetection(minor: 1)],
                authorization: UploadAuthorization(accessToken: "token")
            )
            XCTFail("Expected failure")
        } catch let error as HTTPIngestUploadError {
            XCTAssertEqual(error, .missingDeviceIdentifier)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(client.requests.count, 0)
    }
}
