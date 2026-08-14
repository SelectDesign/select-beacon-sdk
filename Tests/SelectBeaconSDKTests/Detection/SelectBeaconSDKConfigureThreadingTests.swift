import XCTest
@testable import SelectBeaconSDK

@MainActor
final class SelectBeaconSDKConfigureThreadingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SelectBeaconSDK.shared.testingResetSharedEnablementState()
    }

    override func tearDown() {
        SelectBeaconSDK.shared.testingResetSharedEnablementState()
        super.tearDown()
    }

    private func fulfillWhenStatus(
        _ predicate: @escaping (SDKOperationalStatus) -> Bool,
        expectation: XCTestExpectation,
        timeout: TimeInterval = 2
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        Task { @MainActor in
            while Date() < deadline {
                if predicate(SelectBeaconSDK.shared.operationalStatus) {
                    expectation.fulfill()
                    return
                }
                await Task.yield()
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    func testConfigureFromBackgroundThreadDoesNotDeadlockWhenMainWaits() {
        let finished = expectation(description: "configure returned on worker")
        let becameReady = expectation(description: "operationalStatus became ready")
        let worker = DispatchQueue(label: "selectbeacon.configure.worker")
        let semaphore = DispatchSemaphore(value: 0)

        worker.async {
            // If configure used DispatchQueue.main.sync, this deadlocks because
            // the main actor (this test) is blocked on semaphore.wait below.
            SelectBeaconSDK.configure(
                appKey: "bg-key",
                appSecret: "bg-secret"
            )
            semaphore.signal()
            finished.fulfill()
        }

        let waitResult = semaphore.wait(timeout: .now() + 2)
        XCTAssertEqual(
            waitResult,
            .success,
            "configure must not main.sync while main waits on the caller"
        )
        wait(for: [finished], timeout: 0.5)

        fulfillWhenStatus({ $0 == .ready }, expectation: becameReady)
        wait(for: [becameReady], timeout: 2)
        XCTAssertEqual(SelectBeaconSDK.shared.operationalStatus, .ready)
    }

    func testInvalidOffMainConfigureEventuallyDegrades() {
        let degraded = expectation(description: "invalidConfiguration")
        let worker = DispatchQueue(label: "selectbeacon.configure.invalid")
        worker.async {
            SelectBeaconSDK.configure(appKey: "", appSecret: "secret")
        }
        fulfillWhenStatus(
            {
                if case .degraded(.invalidConfiguration) = $0 { return true }
                return false
            },
            expectation: degraded
        )
        wait(for: [degraded], timeout: 2)
        XCTAssertEqual(
            SelectBeaconSDK.shared.operationalStatus,
            .degraded(.invalidConfiguration)
        )
    }

    func testConcurrentOffMainConfiguresAllApplyLastWins() {
        let finished = expectation(description: "both configures returned")
        let lastWins = expectation(description: "last staged outcome wins")
        let worker = DispatchQueue(label: "selectbeacon.configure.fifo")

        // Same off-main caller stages two values in order; FIFO drain must apply
        // both so the last outcome wins (not a dropped single-slot overwrite).
        worker.async {
            SelectBeaconSDK.configure(appKey: "first-key", appSecret: "secret")
            SelectBeaconSDK.configure(appKey: "", appSecret: "secret")
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)

        fulfillWhenStatus(
            {
                if case .degraded(.invalidConfiguration) = $0 { return true }
                return false
            },
            expectation: lastWins
        )
        wait(for: [lastWins], timeout: 2)
        XCTAssertEqual(
            SelectBeaconSDK.shared.operationalStatus,
            .degraded(.invalidConfiguration)
        )
    }
}
