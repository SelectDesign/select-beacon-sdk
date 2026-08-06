import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
final class SelectBeaconSDKConfigurationTests: XCTestCase {
    func testAppIdentityRequiresNonEmptyKeyAndSecret() {
        XCTAssertNil(AppIdentity(appKey: "", appSecret: "secret"))
        XCTAssertNil(AppIdentity(appKey: "key", appSecret: ""))
        XCTAssertNil(AppIdentity(appKey: "  ", appSecret: "secret"))
        XCTAssertNotNil(AppIdentity(appKey: "key", appSecret: "secret"))
    }

    func testProductionEnvironmentIsDefault() {
        let fixture = SDKTestFixture.makeSDK()

        XCTAssertEqual(fixture.sdk.configuredEnvironment, .production)
        XCTAssertEqual(fixture.sdk.configuredEndpoint?.baseURL, APIEndpointDefaults.production)
        XCTAssertEqual(fixture.sdk.operationalStatus, .ready)
    }

    func testStagingEnvironmentRetainsCallerSuppliedEndpoint() {
        let stagingURL = SDKTestFixture.testURL("https://staging-eu.example.com")
        let fixture = SDKTestFixture.makeSDK(environment: .staging(baseURL: stagingURL))

        XCTAssertEqual(fixture.sdk.configuredEnvironment, .staging(baseURL: stagingURL))
        XCTAssertEqual(fixture.sdk.configuredEndpoint?.baseURL, stagingURL.absoluteString)
    }

    func testDifferentStagingEnvironmentsRemainDistinct() {
        let firstURL = SDKTestFixture.testURL("https://staging-one.example.com")
        let secondURL = SDKTestFixture.testURL("https://staging-two.example.com")
        let first = SDKTestFixture.makeSDK(environment: .staging(baseURL: firstURL))
        let second = SDKTestFixture.makeSDK(environment: .staging(baseURL: secondURL))

        XCTAssertNotEqual(first.sdk.configuredEndpoint, second.sdk.configuredEndpoint)
    }

    func testHTTPStagingEndpointIsSupported() {
        let stagingURL = SDKTestFixture.testURL("http://staging.example.com")
        let fixture = SDKTestFixture.makeSDK(environment: .staging(baseURL: stagingURL))

        XCTAssertEqual(fixture.sdk.configuredEndpoint?.baseURL, stagingURL.absoluteString)
    }

    func testNonHTTPStagingEndpointDoesNotConfigureSDK() {
        let fixture = SDKTestFixture.makeSDK(
            environment: .staging(baseURL: URL(fileURLWithPath: "/tmp/staging"))
        )

        fixture.sdk.start()

        XCTAssertNil(fixture.sdk.configuredEnvironment)
        XCTAssertTrue(fixture.engine.startedUUIDs.isEmpty)
        XCTAssertEqual(
            fixture.sdk.operationalStatus,
            .degraded(.startRequestedBeforeConfiguration)
        )
    }

    func testConfigurationCannotChangeAfterStart() {
        let fixture = SDKTestFixture.makeSDK()
        fixture.sdk.start()
        XCTAssertEqual(fixture.sdk.operationalStatus, .ranging)

        let stagingURL = SDKTestFixture.testURL("https://staging.example.com")
        guard let stagingIdentity = AppIdentity(appKey: "staging-key", appSecret: "test-secret") else {
            return XCTFail("Test app identity should be valid")
        }

        fixture.sdk.configure(
            identity: stagingIdentity,
            environment: .staging(baseURL: stagingURL)
        )

        XCTAssertEqual(fixture.sdk.configuredEnvironment, .production)
        XCTAssertEqual(fixture.sdk.configuredEndpoint?.baseURL, APIEndpointDefaults.production)
        XCTAssertEqual(fixture.sdk.operationalStatus, .degraded(.configurationLocked))
    }

    func testInvalidReplacementConfigurationClearsPriorEnablement() {
        let fixture = SDKTestFixture.makeSDK()
        guard let replacement = AppIdentity(appKey: "replacement-key", appSecret: "test-secret") else {
            return XCTFail("Test app identity should be valid")
        }

        fixture.sdk.configure(
            identity: replacement,
            environment: .staging(baseURL: URL(fileURLWithPath: "/invalid"))
        )
        fixture.sdk.start()

        XCTAssertNil(fixture.sdk.configuredEnvironment)
        XCTAssertTrue(fixture.engine.startedUUIDs.isEmpty)
        XCTAssertEqual(
            fixture.sdk.operationalStatus,
            .degraded(.startRequestedBeforeConfiguration)
        )
    }

    func testPreStartReconfigurationCreatesQueueForNewNamespace() async throws {
        let engine = FakeEngine()
        let permission = FakePermissionObserver(authorization: .always)
        let lifecycle = FakeLifecycleObserver(isActive: true)
        var storageIdentifiers: [String] = []
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { permission },
            lifecycleObserver: { lifecycle },
            clock: FixedClock(now: Date(timeIntervalSince1970: 1_000_000)),
            queue: { storageIdentifier in
                storageIdentifiers.append(storageIdentifier)
                return InMemoryQueue()
            },
            identity: AppIdentity(appKey: "first-key", appSecret: "test-secret")
        )

        _ = try await sdk.selectPendingReports()
        guard let secondKey = AppIdentity(appKey: "second-key", appSecret: "test-secret") else {
            return XCTFail("Test app identity should be valid")
        }
        sdk.configure(
            identity: secondKey,
            environment: .staging(baseURL: SDKTestFixture.testURL("https://staging.example.com"))
        )
        _ = try await sdk.selectPendingReports()

        XCTAssertEqual(storageIdentifiers.count, 2)
        XCTAssertNotEqual(storageIdentifiers[0], storageIdentifiers[1])
    }

    func testUnconfiguredStartIsQuiet() {
        let fixture = SDKTestFixture.makeSDK(identity: nil)

        fixture.sdk.start()

        XCTAssertTrue(fixture.engine.startedUUIDs.isEmpty)
        XCTAssertEqual(
            fixture.sdk.operationalStatus,
            .degraded(.startRequestedBeforeConfiguration)
        )
    }

    func testAlwaysAuthorizationStartsSingleSelectUUID() {
        let fixture = SDKTestFixture.makeSDK(authorization: .always, isActive: false)

        fixture.sdk.start()

        XCTAssertEqual(fixture.engine.startedUUIDs, [[SDKTestFixture.fleetUUID]])
        XCTAssertEqual(fixture.sdk.operationalStatus, .ranging)
    }

    func testWhenInUseAuthorizationOnlyRangesInForeground() {
        let fixture = SDKTestFixture.makeSDK(authorization: .whenInUse, isActive: true)

        fixture.sdk.start()
        XCTAssertEqual(fixture.engine.startedUUIDs.count, 1)
        XCTAssertEqual(fixture.sdk.operationalStatus, .ranging)

        fixture.lifecycle.setActive(false)
        XCTAssertEqual(fixture.engine.stopCount, 1)
        XCTAssertEqual(fixture.sdk.operationalStatus, .paused)

        fixture.lifecycle.setActive(true)
        XCTAssertEqual(fixture.engine.startedUUIDs.count, 2)
        XCTAssertEqual(fixture.sdk.operationalStatus, .ranging)
    }

    func testAlwaysBackgroundKeepsEngineStartedAndSyncsApplicationActive() {
        let fixture = SDKTestFixture.makeSDK(authorization: .always, isActive: true)

        fixture.sdk.start()
        XCTAssertEqual(fixture.engine.startedUUIDs.count, 1)
        XCTAssertFalse(fixture.engine.applicationActiveValues.isEmpty)
        XCTAssertEqual(fixture.engine.applicationActiveValues.last, true)
        let stopCountAfterStart = fixture.engine.stopCount

        fixture.lifecycle.setActive(false)

        XCTAssertEqual(fixture.engine.stopCount, stopCountAfterStart)
        XCTAssertEqual(fixture.engine.applicationActiveValues.last, false)
        XCTAssertEqual(fixture.sdk.operationalStatus, .ranging)
    }

    func testNotDeterminedIsQuietUntilHostGrantsAuthorization() {
        let fixture = SDKTestFixture.makeSDK(authorization: .notDetermined)

        fixture.sdk.start()
        XCTAssertTrue(fixture.engine.startedUUIDs.isEmpty)
        XCTAssertEqual(fixture.sdk.operationalStatus, .awaitingPermission)

        fixture.permission.setAuthorization(.always)
        XCTAssertEqual(fixture.engine.startedUUIDs, [[SDKTestFixture.fleetUUID]])
        XCTAssertEqual(fixture.sdk.operationalStatus, .ranging)
    }

    func testAuthorizationRevocationStopsRangingWithoutHostError() {
        let fixture = SDKTestFixture.makeSDK()

        fixture.sdk.start()
        fixture.permission.setAuthorization(.unavailable)

        XCTAssertEqual(fixture.engine.stopCount, 1)
        XCTAssertEqual(
            fixture.sdk.operationalStatus,
            .degraded(.locationPermissionUnavailable)
        )
    }

    func testStopPreventsLaterPermissionChangesFromRestartingRanging() {
        let fixture = SDKTestFixture.makeSDK()

        fixture.sdk.start()
        fixture.sdk.stop()
        XCTAssertEqual(fixture.sdk.operationalStatus, .ready)

        fixture.permission.setAuthorization(.whenInUse)

        XCTAssertEqual(fixture.engine.startedUUIDs.count, 1)
        XCTAssertEqual(fixture.engine.stopCount, 1)
        XCTAssertEqual(fixture.sdk.operationalStatus, .ready)
    }
}
