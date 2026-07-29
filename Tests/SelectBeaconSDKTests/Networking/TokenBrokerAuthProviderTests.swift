import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
final class TokenBrokerAuthProviderTests: XCTestCase {
    private enum TestSetupError: Error {
        case invalidConfiguration
    }

    private final class MutableClock: Clock {
        var now: Date

        init(now: Date) {
            self.now = now
        }
    }

    private actor FakeHTTPDataLoader: HTTPDataLoading {
        private struct TokenPayload: Encodable {
            let accessToken: String
            let expiresIn: TimeInterval

            enum CodingKeys: String, CodingKey {
                case accessToken = "access-token"
                case expiresIn = "expires-in"
            }
        }

        enum Outcome {
            case token(value: String, expiresIn: TimeInterval, statusCode: Int)
            case networkFailure
        }

        private var outcomes: [Outcome]
        private let delayNanoseconds: UInt64
        private var requests: [URLRequest] = []

        init(outcomes: [Outcome], delayNanoseconds: UInt64 = 0) {
            self.outcomes = outcomes
            self.delayNanoseconds = delayNanoseconds
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)

            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }

            guard !outcomes.isEmpty else {
                throw TokenBrokerAuthError.networkRequestFailed
            }

            let outcome = outcomes.removeFirst()
            switch outcome {
            case .networkFailure:
                throw TokenBrokerAuthError.networkRequestFailed
            case .token(let value, let expiresIn, let statusCode):
                let body = try JSONEncoder().encode(
                    TokenPayload(accessToken: value, expiresIn: expiresIn)
                )
                let response = HTTPURLResponse(
                    url: request.url ?? URL(fileURLWithPath: "/"),
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? URLResponse(
                    url: request.url ?? URL(fileURLWithPath: "/"),
                    mimeType: nil,
                    expectedContentLength: 0,
                    textEncodingName: nil
                )
                return (body, response)
            }
        }

        func requestCount() -> Int {
            requests.count
        }

        func firstRequestBody() -> Data? {
            requests.first?.httpBody
        }
    }

    private let initialDate = Date(timeIntervalSince1970: 1_000_000)

    private func makeProvider(
        client: FakeHTTPDataLoader,
        clock: Clock,
        refreshSafetyMargin: TimeInterval = 60
    ) throws -> TokenBrokerAuthProvider {
        guard let tokenEndpoint = URL(string: "https://api.select.example.com/ingest/auth/v1"),
              let identity = AppIdentity(appKey: "select-app-key"),
              let configuration = TokenBrokerConfiguration(
                  identity: identity,
                  tokenEndpoint: tokenEndpoint
              ) else {
            throw TestSetupError.invalidConfiguration
        }

        return TokenBrokerAuthProvider(
            configuration: configuration,
            httpClient: client,
            clock: clock,
            refreshSafetyMargin: refreshSafetyMargin
        )
    }

    func testReturnsCachedTokenWhileItIsStillValid() async throws {
        let clock = MutableClock(now: initialDate)
        let client = FakeHTTPDataLoader(outcomes: [
            .token(value: "cached-token", expiresIn: 300, statusCode: 200),
        ])
        let provider = try makeProvider(client: client, clock: clock)

        let firstToken = try await provider.validToken()
        let secondToken = try await provider.validToken()
        let requestCount = await client.requestCount()

        XCTAssertEqual(firstToken, "cached-token")
        XCTAssertEqual(secondToken, "cached-token")
        XCTAssertEqual(requestCount, 1)
    }

    func testRequestsTokenWhenNoTokenIsCached() async throws {
        let client = FakeHTTPDataLoader(outcomes: [
            .token(value: "new-token", expiresIn: 300, statusCode: 200),
        ])
        let provider = try makeProvider(
            client: client,
            clock: MutableClock(now: initialDate)
        )

        let token = try await provider.validToken()
        let requestCount = await client.requestCount()
        let requestBody = await client.firstRequestBody()
        let unwrappedRequestBody = try XCTUnwrap(requestBody)
        let request = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: unwrappedRequestBody) as? [String: String]
        )

        XCTAssertEqual(token, "new-token")
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(request, ["app-key": "select-app-key"])
    }

    func testRefreshesTokenWithinSafetyMargin() async throws {
        let clock = MutableClock(now: initialDate)
        let client = FakeHTTPDataLoader(outcomes: [
            .token(value: "first-token", expiresIn: 120, statusCode: 200),
            .token(value: "refreshed-token", expiresIn: 300, statusCode: 200),
        ])
        let provider = try makeProvider(client: client, clock: clock)

        let firstToken = try await provider.validToken()
        clock.now = initialDate.addingTimeInterval(60)
        let refreshedToken = try await provider.validToken()
        let requestCount = await client.requestCount()

        XCTAssertEqual(firstToken, "first-token")
        XCTAssertEqual(refreshedToken, "refreshed-token")
        XCTAssertEqual(requestCount, 2)
    }

    func testConcurrentRequestsShareOneRefresh() async throws {
        let client = FakeHTTPDataLoader(
            outcomes: [.token(value: "shared-token", expiresIn: 300, statusCode: 200)],
            delayNanoseconds: 50_000_000
        )
        let provider = try makeProvider(
            client: client,
            clock: MutableClock(now: initialDate)
        )

        async let first = provider.validToken()
        async let second = provider.validToken()

        let firstToken = try await first
        let secondToken = try await second
        let requestCount = await client.requestCount()

        XCTAssertEqual(firstToken, "shared-token")
        XCTAssertEqual(secondToken, "shared-token")
        XCTAssertEqual(requestCount, 1)
    }

    func testTokenEndpointFailureIsTyped() async throws {
        let client = FakeHTTPDataLoader(outcomes: [.networkFailure])
        let provider = try makeProvider(
            client: client,
            clock: MutableClock(now: initialDate)
        )

        do {
            _ = try await provider.validToken()
            XCTFail("Expected token retrieval to fail")
        } catch let error as TokenBrokerAuthError {
            XCTAssertEqual(error, .networkRequestFailed)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testTokenIsNeverWrittenToDetectionQueue() async throws {
        let client = FakeHTTPDataLoader(outcomes: [
            .token(value: "memory-only-token", expiresIn: 300, statusCode: 200),
        ])
        let provider = try makeProvider(
            client: client,
            clock: MutableClock(now: initialDate)
        )
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/pending-detections.json")
        let queue = FileDetectionQueue(
            storageIdentifier: "test",
            fileStore: fileStore,
            fileURL: fileURL
        )
        let detection = QueuedDetectionFixtures.make(latestTimestamp: initialDate)

        try await queue.enqueue(detection)
        let token = try await provider.validToken()

        let persistedQueue = try XCTUnwrap(fileStore.files[fileURL])
        let persistedText = try XCTUnwrap(String(data: persistedQueue, encoding: .utf8))
        XCTAssertEqual(token, "memory-only-token")
        XCTAssertFalse(persistedText.contains("memory-only-token"))
    }
}
