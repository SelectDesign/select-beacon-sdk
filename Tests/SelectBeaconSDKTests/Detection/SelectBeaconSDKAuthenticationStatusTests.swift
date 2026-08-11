import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

/// Facade coverage for `.degraded(.authenticationFailed)` signal + retry self-heal.
@MainActor
final class SelectBeaconSDKAuthenticationStatusTests: XCTestCase {
    final class ControllableAuthProvider: AuthProvider {
        var error: Error?
        private(set) var tokenCallCount = 0

        func validAuthorization() async throws -> UploadAuthorization {
            tokenCallCount += 1
            if let error {
                throw error
            }
            return UploadAuthorization(accessToken: "ok-token")
        }

        func invalidateCachedToken() {}
    }

    final class AcceptingTransport: UploadTransport {
        func upload(
            detections: [QueuedDetection],
            authorization: UploadAuthorization
        ) async throws -> UploadResponse {
            .accepted(acknowledgedIDs: detections.map(\.id))
        }
    }

    func testUnauthorizedAuthDegradesThenClearsOnSuccessfulMintWithoutReconfigure() async throws {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let detection = QueuedDetectionFixtures.make(minor: 9)
        _ = try await queue.enqueue(detection, now: detection.queuedAt)

        let auth = ControllableAuthProvider()
        auth.error = TokenBrokerAuthError.unauthorized(statusCode: 403)
        let stagingURL = SDKTestFixture.testURL("https://staging.example.com")
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { FakeLifecycleObserver(isActive: true) },
            clock: MutableClock(),
            queue: { _ in queue },
            locationProvider: { FakeLocationProvider() },
            networkPathObserver: { FakeNetworkPathObserver() },
            identity: AppIdentity(appKey: "customer-key", appSecret: "test-secret"),
            environment: .staging(baseURL: stagingURL)
        )
        sdk.selectInstallUploadSeams(auth: auth, transport: AcceptingTransport())

        let degraded = expectation(description: "authenticationFailed")
        sdk.onOperationalStatusChanged = { status in
            if case .degraded(.authenticationFailed) = status {
                degraded.fulfill()
            }
        }

        sdk.start()
        await fulfillment(of: [degraded], timeout: 2)
        XCTAssertEqual(sdk.operationalStatus, .degraded(.authenticationFailed))
        XCTAssertEqual(queue.records.count, 1)

        // Same credentials; suspension lifted — no new configure/identity.
        auth.error = nil
        sdk.stop()

        let recovered = expectation(description: "auth recovered to ranging")
        sdk.onOperationalStatusChanged = { status in
            if status == .ranging {
                recovered.fulfill()
            }
        }
        sdk.start()
        await fulfillment(of: [recovered], timeout: 2)

        let drained = expectation(description: "queue drained")
        Task { @MainActor in
            for _ in 0..<200 {
                if queue.records.isEmpty {
                    drained.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(sdk.operationalStatus, .ranging)
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testAuthenticationFailedSurvivesLifecycleSessionStatusUpdates() async throws {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let detection = QueuedDetectionFixtures.make(minor: 11)
        _ = try await queue.enqueue(detection, now: detection.queuedAt)

        let lifecycle = FakeLifecycleObserver(isActive: true)
        let auth = ControllableAuthProvider()
        auth.error = TokenBrokerAuthError.unauthorized(statusCode: 401)
        let stagingURL = SDKTestFixture.testURL("https://staging.example.com")
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { lifecycle },
            clock: MutableClock(),
            queue: { _ in queue },
            locationProvider: { FakeLocationProvider() },
            networkPathObserver: { FakeNetworkPathObserver() },
            identity: AppIdentity(appKey: "customer-key", appSecret: "test-secret"),
            environment: .staging(baseURL: stagingURL)
        )
        sdk.selectInstallUploadSeams(auth: auth, transport: AcceptingTransport())

        let degraded = expectation(description: "authenticationFailed")
        sdk.onOperationalStatusChanged = { status in
            if case .degraded(.authenticationFailed) = status {
                degraded.fulfill()
            }
        }
        sdk.start()
        await fulfillment(of: [degraded], timeout: 2)

        lifecycle.setActive(false)
        lifecycle.setActive(true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sdk.operationalStatus, .degraded(.authenticationFailed))
    }

    func testNetworkAuthFailureDoesNotSetAuthenticationFailedStatus() async throws {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let detection = QueuedDetectionFixtures.make(minor: 10)
        _ = try await queue.enqueue(detection, now: detection.queuedAt)

        let auth = ControllableAuthProvider()
        auth.error = TokenBrokerAuthError.networkRequestFailed
        let stagingURL = SDKTestFixture.testURL("https://staging.example.com")
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { FakeLifecycleObserver(isActive: true) },
            clock: MutableClock(),
            queue: { _ in queue },
            locationProvider: { FakeLocationProvider() },
            networkPathObserver: { FakeNetworkPathObserver() },
            identity: AppIdentity(appKey: "customer-key", appSecret: "test-secret"),
            environment: .staging(baseURL: stagingURL)
        )
        sdk.selectInstallUploadSeams(auth: auth, transport: AcceptingTransport())

        var sawAuthFailed = false
        sdk.onOperationalStatusChanged = { status in
            if case .degraded(.authenticationFailed) = status {
                sawAuthFailed = true
            }
        }

        sdk.start()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(sawAuthFailed)
        XCTAssertNotEqual(sdk.operationalStatus, .degraded(.authenticationFailed))
        XCTAssertEqual(sdk.operationalStatus, .ranging)
    }
}
