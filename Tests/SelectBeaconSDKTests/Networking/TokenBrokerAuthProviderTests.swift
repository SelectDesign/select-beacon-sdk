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
            let tokenType: String
            let expiresIn: TimeInterval

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case tokenType = "token_type"
                case expiresIn = "expires_in"
            }
        }

        enum Outcome {
            case token(value: String, tokenType: String, expiresIn: TimeInterval, statusCode: Int)
            case httpStatus(statusCode: Int, headerFields: [String: String]?)
            case networkFailure
        }

        private var outcomes: [Outcome]
        private let delayNanoseconds: UInt64
        private let ignoreCancellationDuringDelay: Bool
        private var requests: [URLRequest] = []

        init(
            outcomes: [Outcome],
            delayNanoseconds: UInt64 = 0,
            ignoreCancellationDuringDelay: Bool = false
        ) {
            self.outcomes = outcomes
            self.delayNanoseconds = delayNanoseconds
            self.ignoreCancellationDuringDelay = ignoreCancellationDuringDelay
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)

            if delayNanoseconds > 0 {
                if ignoreCancellationDuringDelay {
                    let ns = delayNanoseconds
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(ns))) {
                            cont.resume()
                        }
                    }
                } else {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
            }

            guard !outcomes.isEmpty else {
                throw TokenBrokerAuthError.networkRequestFailed
            }

            let outcome = outcomes.removeFirst()
            let url = request.url ?? URL(fileURLWithPath: "/")
            switch outcome {
            case .networkFailure:
                throw TokenBrokerAuthError.networkRequestFailed
            case .httpStatus(let statusCode, let headerFields):
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: headerFields
                ) ?? URLResponse(
                    url: url,
                    mimeType: nil,
                    expectedContentLength: 0,
                    textEncodingName: nil
                )
                return (Data(), response)
            case .token(let value, let tokenType, let expiresIn, let statusCode):
                let body = try JSONEncoder().encode(
                    TokenPayload(accessToken: value, tokenType: tokenType, expiresIn: expiresIn)
                )
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? URLResponse(
                    url: url,
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
        guard let tokenEndpoint = URL(string: "https://api.select.example.com/auth/v1"),
              let identity = AppIdentity(appKey: "select-app-key", appSecret: "select-app-secret"),
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
            .token(value: "cached-token", tokenType: "Bearer", expiresIn: 300, statusCode: 200),
        ])
        let provider = try makeProvider(client: client, clock: clock)

        let first = try await provider.validAuthorization()
        let second = try await provider.validAuthorization()
        let requestCount = await client.requestCount()

        XCTAssertEqual(first.accessToken, "cached-token")
        XCTAssertEqual(first.headerValue, "Bearer cached-token")
        XCTAssertEqual(second.accessToken, "cached-token")
        XCTAssertEqual(requestCount, 1)
    }

    func testRequestsTokenWhenNoTokenIsCached() async throws {
        let client = FakeHTTPDataLoader(outcomes: [
            .token(value: "new-token", tokenType: "Bearer", expiresIn: 300, statusCode: 200),
        ])
        let provider = try makeProvider(
            client: client,
            clock: MutableClock(now: initialDate)
        )

        let authorization = try await provider.validAuthorization()
        let requestCount = await client.requestCount()
        let requestBody = await client.firstRequestBody()
        let unwrappedRequestBody = try XCTUnwrap(requestBody)
        let request = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: unwrappedRequestBody) as? [String: String]
        )

        XCTAssertEqual(authorization.accessToken, "new-token")
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(
            request,
            ["app_key": "select-app-key", "app_secret": "select-app-secret"]
        )
    }

    func testRefreshesTokenWithinSafetyMargin() async throws {
        let clock = MutableClock(now: initialDate)
        let client = FakeHTTPDataLoader(outcomes: [
            .token(value: "first-token", tokenType: "Bearer", expiresIn: 120, statusCode: 200),
            .token(value: "refreshed-token", tokenType: "Bearer", expiresIn: 300, statusCode: 200),
        ])
        let provider = try makeProvider(client: client, clock: clock)

        let first = try await provider.validAuthorization()
        clock.now = initialDate.addingTimeInterval(60)
        let refreshed = try await provider.validAuthorization()
        let requestCount = await client.requestCount()

        XCTAssertEqual(first.accessToken, "first-token")
        XCTAssertEqual(refreshed.accessToken, "refreshed-token")
        XCTAssertEqual(requestCount, 2)
    }

    func testConcurrentRequestsShareOneRefresh() async throws {
        let client = FakeHTTPDataLoader(
            outcomes: [
                .token(value: "shared-token", tokenType: "Bearer", expiresIn: 300, statusCode: 200),
            ],
            delayNanoseconds: 50_000_000
        )
        let provider = try makeProvider(
            client: client,
            clock: MutableClock(now: initialDate)
        )

        async let first = provider.validAuthorization()
        async let second = provider.validAuthorization()

        let firstAuth = try await first
        let secondAuth = try await second
        let requestCount = await client.requestCount()

        XCTAssertEqual(firstAuth.accessToken, "shared-token")
        XCTAssertEqual(secondAuth.accessToken, "shared-token")
        XCTAssertEqual(requestCount, 1)
    }

    func testTokenEndpointFailureIsTyped() async throws {
        let client = FakeHTTPDataLoader(outcomes: [.networkFailure])
        let provider = try makeProvider(
            client: client,
            clock: MutableClock(now: initialDate)
        )

        do {
            _ = try await provider.validAuthorization()
            XCTFail("Expected token retrieval to fail")
        } catch let error as TokenBrokerAuthError {
            XCTAssertEqual(error, .networkRequestFailed)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRateLimitedHonorsRetryAfterHeader() async throws {
        let client = FakeHTTPDataLoader(outcomes: [
            .httpStatus(statusCode: 429, headerFields: ["Retry-After": "45"]),
        ])
        let provider = try makeProvider(
            client: client,
            clock: MutableClock(now: initialDate)
        )

        do {
            _ = try await provider.validAuthorization()
            XCTFail("Expected rate-limited token retrieval to fail")
        } catch let error as TokenBrokerAuthError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 45))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRateLimitedWithoutRetryAfterUsesNilDelay() async throws {
        let client = FakeHTTPDataLoader(outcomes: [
            .httpStatus(statusCode: 429, headerFields: nil),
        ])
        let provider = try makeProvider(
            client: client,
            clock: MutableClock(now: initialDate)
        )

        do {
            _ = try await provider.validAuthorization()
            XCTFail("Expected rate-limited token retrieval to fail")
        } catch let error as TokenBrokerAuthError {
            XCTAssertEqual(error, .rateLimited(retryAfter: nil))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testUnauthorizedStatusIsTypedAndHostVisible() async throws {
        let client = FakeHTTPDataLoader(outcomes: [
            .httpStatus(statusCode: 401, headerFields: nil),
        ])
        let provider = try makeProvider(
            client: client,
            clock: MutableClock(now: initialDate)
        )

        do {
            _ = try await provider.validAuthorization()
            XCTFail("Expected unauthorized token retrieval to fail")
        } catch let error as TokenBrokerAuthError {
            XCTAssertEqual(error, .unauthorized(statusCode: 401))
            XCTAssertTrue(error.isHostVisibleAuthenticationFailure)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testNetworkFailureIsNotHostVisible() {
        XCTAssertFalse(TokenBrokerAuthError.networkRequestFailed.isHostVisibleAuthenticationFailure)
        XCTAssertTrue(TokenBrokerAuthError.invalidEndpoint.isHostVisibleAuthenticationFailure)
        XCTAssertTrue(TokenBrokerAuthError.invalidResponse.isHostVisibleAuthenticationFailure)
    }

    func testTokenIsNeverWrittenToDetectionQueue() async throws {
        let client = FakeHTTPDataLoader(outcomes: [
            .token(value: "memory-only-token", tokenType: "Bearer", expiresIn: 300, statusCode: 200),
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

        try await queue.enqueue(detection, now: Date(timeIntervalSince1970: 1_000_000))
        let authorization = try await provider.validAuthorization()

        let persistedQueue = try XCTUnwrap(fileStore.files[fileURL])
        let persistedText = try XCTUnwrap(String(data: persistedQueue, encoding: .utf8))
        XCTAssertEqual(authorization.accessToken, "memory-only-token")
        XCTAssertFalse(persistedText.contains("memory-only-token"))
        XCTAssertFalse(persistedText.contains("select-app-secret"))
    }
    func testInvalidatePreventsLateResponseFromRepopulatingCache() async throws {
        let client = FakeHTTPDataLoader(
            outcomes: [
                .token(value: "stale-token", tokenType: "Bearer", expiresIn: 300, statusCode: 200),
                .token(value: "fresh-token", tokenType: "Bearer", expiresIn: 300, statusCode: 200),
            ],
            delayNanoseconds: 80_000_000,
            ignoreCancellationDuringDelay: true
        )
        let provider = try makeProvider(
            client: client,
            clock: MutableClock(now: initialDate)
        )

        let inFlight = Task { @MainActor in
            try await provider.validAuthorization()
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        provider.invalidateCachedToken()
        do {
            _ = try await inFlight.value
            XCTFail("Expected in-flight refresh to fail after invalidate")
        } catch is CancellationError {
            // Expected — generation bumped / task cancelled.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let authorization = try await provider.validAuthorization()
        let requestCount = await client.requestCount()

        XCTAssertEqual(authorization.accessToken, "fresh-token")
        XCTAssertEqual(requestCount, 2)
    }
}
