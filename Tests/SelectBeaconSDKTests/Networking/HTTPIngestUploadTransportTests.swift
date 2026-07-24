import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
final class HTTPIngestUploadTransportTests: XCTestCase {
    private final class FakeDeviceIdentifier: DeviceIdentifying {
        var deviceId: String?

        init(deviceId: String? = "device-123") {
            self.deviceId = deviceId
        }
    }

    private final class FakeHTTPDataLoader: HTTPDataLoading, @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        var statusCode = 200
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
                headerFields: nil
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
            ingestURL: URL(string: "https://api.select.example.com/ingest/sdk/v1")!,
            httpClient: client,
            deviceIdentifier: FakeDeviceIdentifier()
        )

        let response = try await transport.upload(
            detections: detections,
            bearerToken: "token-abc"
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
            HTTPIngestUploadTransport.jsonAPIContentType
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            HTTPIngestUploadTransport.jsonAPIContentType
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(json["data"] as? [[String: Any]])
        XCTAssertEqual(data.count, 2)
        XCTAssertEqual(data.first?["type"] as? String, "sdk_beacon")
        XCTAssertNil(data.first?["id"])
    }

    func testNon200Throws() async {
        let client = FakeHTTPDataLoader()
        client.statusCode = 500
        let transport = HTTPIngestUploadTransport(
            ingestURL: URL(string: "https://api.select.example.com/ingest/sdk/v1")!,
            httpClient: client,
            deviceIdentifier: FakeDeviceIdentifier()
        )

        do {
            _ = try await transport.upload(
                detections: [makeDetection(minor: 1)],
                bearerToken: "token"
            )
            XCTFail("Expected failure")
        } catch let error as HTTPIngestUploadError {
            XCTAssertEqual(error, .unexpectedStatusCode(500))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingDeviceIdThrowsBeforeNetwork() async {
        let client = FakeHTTPDataLoader()
        let transport = HTTPIngestUploadTransport(
            ingestURL: URL(string: "https://api.select.example.com/ingest/sdk/v1")!,
            httpClient: client,
            deviceIdentifier: FakeDeviceIdentifier(deviceId: nil)
        )

        do {
            _ = try await transport.upload(
                detections: [makeDetection(minor: 1)],
                bearerToken: "token"
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
