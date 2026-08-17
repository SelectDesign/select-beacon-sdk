import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK
@testable import SelectBeaconSDKTestSupport

@MainActor
final class SelectBeaconSDKColdStartUploadTests: XCTestCase {
    final class CountingTransport: UploadTransport {
        private(set) var uploads: [[QueuedDetection]] = []

        func upload(
            detections: [QueuedDetection],
            authorization: UploadAuthorization
        ) async throws -> UploadResponse {
            _ = authorization
            uploads.append(detections)
            return .accepted(acknowledgedIDs: detections.map(\.id))
        }
    }

    final class CountingAuth: AuthProvider {
        func validAuthorization() async throws -> UploadAuthorization {
            UploadAuthorization(accessToken: "token")
        }
        func invalidateCachedToken() {}
    }

    func testColdStartMaterializesDiskBacklogAndFlushesWhenOnline() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/pending-cold.json")
        let deadLetterURL = URL(fileURLWithPath: "/queue/dead-cold.json")
        let detection = QueuedDetectionFixtures.make(minor: 77)

        let seedQueue = FileDetectionQueue(
            storageIdentifier: "cold",
            fileStore: fileStore,
            fileURL: fileURL,
            deadLetterURL: deadLetterURL
        )
        _ = try await seedQueue.enqueue(detection, now: Date(timeIntervalSince1970: 1_000_000))

        let path = FakeNetworkPathObserver(isSatisfied: true)
        let transport = CountingTransport()
        let maxAge = ManualDelayedActionScheduler()
        let sdk = SelectBeaconSDK(
            engine: { FakeEngine() },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { FakeLifecycleObserver(isActive: true) },
            clock: MutableClock(now: Date(timeIntervalSince1970: 1_000_100)),
            queue: { _ in
                FileDetectionQueue(
                    storageIdentifier: "cold",
                    fileStore: fileStore,
                    fileURL: fileURL,
                    deadLetterURL: deadLetterURL
                )
            },
            authProvider: { CountingAuth() },
            uploadTransport: { transport },
            networkPathObserver: { path },
            maxAgeScheduler: { maxAge },
            deviceIdentifier: { FixedDeviceIdentifier() },
            identity: AppIdentity(appKey: "customer-key", appSecret: "test-secret"),
            environment: .staging(baseURL: URL(string: "https://staging.example.com")!)
        )
        sdk.selectInstallUploadSeams(auth: CountingAuth(), transport: transport)

        sdk.start()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while transport.uploads.isEmpty,
              DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(transport.uploads.first?.map(\.minor), [77])
        let pending = try await sdk.selectPendingReports()
        XCTAssertTrue(pending.isEmpty)
    }

    func testColdStartOfflineRetainsDiskBacklogUntilConnectivity() async throws {
        let fileStore = MemoryFileStore()
        let fileURL = URL(fileURLWithPath: "/queue/pending-cold-offline.json")
        let deadLetterURL = URL(fileURLWithPath: "/queue/dead-cold-offline.json")
        let detection = QueuedDetectionFixtures.make(minor: 88)

        let seedQueue = FileDetectionQueue(
            storageIdentifier: "cold-offline",
            fileStore: fileStore,
            fileURL: fileURL,
            deadLetterURL: deadLetterURL
        )
        _ = try await seedQueue.enqueue(detection, now: Date(timeIntervalSince1970: 1_000_000))

        let path = FakeNetworkPathObserver(isSatisfied: false)
        let transport = CountingTransport()
        let sdk = SelectBeaconSDK(
            engine: { FakeEngine() },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { FakeLifecycleObserver(isActive: true) },
            clock: MutableClock(now: Date(timeIntervalSince1970: 1_000_100)),
            queue: { _ in
                FileDetectionQueue(
                    storageIdentifier: "cold-offline",
                    fileStore: fileStore,
                    fileURL: fileURL,
                    deadLetterURL: deadLetterURL
                )
            },
            authProvider: { CountingAuth() },
            uploadTransport: { transport },
            networkPathObserver: { path },
            deviceIdentifier: { FixedDeviceIdentifier() },
            identity: AppIdentity(appKey: "customer-key", appSecret: "test-secret"),
            environment: .staging(baseURL: URL(string: "https://staging.example.com")!)
        )
        sdk.selectInstallUploadSeams(auth: CountingAuth(), transport: transport)

        sdk.start()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(transport.uploads.isEmpty)
        var pending = try await sdk.selectPendingReports()
        XCTAssertEqual(pending.map(\.minor), [88])

        path.setSatisfied(true)
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while transport.uploads.isEmpty,
              DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(transport.uploads.first?.map(\.minor), [88])
        pending = try await sdk.selectPendingReports()
        XCTAssertTrue(pending.isEmpty)
    }
}

private struct FixedDeviceIdentifier: DeviceIdentifying {
    var deviceId: String? { "test-device-id" }
}
