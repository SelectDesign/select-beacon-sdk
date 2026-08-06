import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
final class SelectBeaconSDKStopFinalizeTests: XCTestCase {
    func testStopFinalizesOpenWindowsAndDelivers() async throws {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let sdk = SDKTestFixture.makeSDK(engine: engine, queue: { _ in queue })
        let pending = expectation(description: "Pending after stop finalize")
        sdk.onSelectPendingReportsChanged = { reports in
            XCTAssertEqual(reports.map(\.minor), [42])
            pending.fulfill()
        }

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        sdk.stop()

        await fulfillment(of: [pending], timeout: 1)
        let queuedDetections = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(queuedDetections.count, 1)
        XCTAssertEqual(queuedDetections.first?.minor, 42)
        XCTAssertFalse(sdk.selectIsStopFinalizePending)
    }

    func testStopFinalizeSurvivesImmediateStart() async throws {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = SDKTestFixture.makeSDK(engine: engine, queue: { _ in queue })
        let pending = expectation(description: "Stop-finalize pending after restart")
        sdk.onSelectPendingReportsChanged = { reports in
            XCTAssertEqual(reports.map(\.minor), [42])
            pending.fulfill()
        }

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        // Leave the window open so stop() must finalize and enqueue it.
        sdk.stop()
        await queue.waitForWriteStart()

        // Immediate restart must not abandon the stop-finalize enqueue.
        sdk.start()

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [pending], timeout: 1)

        let queuedDetections = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(queuedDetections.map(\.minor), [42])
        XCTAssertFalse(sdk.selectIsStopFinalizePending)
    }

    func testStopFinalizePendingTracksBlockedEnqueue() async {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = SDKTestFixture.makeSDK(engine: engine, queue: { _ in queue })
        var pendingValues: [Bool] = []
        let becamePending = expectation(description: "Stop finalize became pending")
        let cleared = expectation(description: "Stop finalize cleared")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            pendingValues.append(pending)
            if pending {
                becamePending.fulfill()
            } else if pendingValues.contains(true) {
                cleared.fulfill()
            }
        }

        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        sdk.stop()

        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        XCTAssertTrue(sdk.selectOpenWindowSnapshots.isEmpty)
        await fulfillment(of: [becamePending], timeout: 1)
        await queue.waitForWriteStart()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [cleared], timeout: 1)

        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true, false])
    }

    func testStopFinalizePendingSurvivesImmediateStart() async {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = SDKTestFixture.makeSDK(engine: engine, queue: { _ in queue })
        let cleared = expectation(description: "Pending clears after restart write")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            if !pending {
                cleared.fulfill()
            }
        }

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        sdk.stop()
        await queue.waitForWriteStart()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)

        sdk.start()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [cleared], timeout: 1)
        XCTAssertFalse(sdk.selectIsStopFinalizePending)
    }

    func testStopWithoutOpenWindowsDoesNotSetFinalizePending() {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let sdk = SDKTestFixture.makeSDK(engine: engine, queue: { _ in queue })
        var pendingValues: [Bool] = []
        sdk.onSelectStopFinalizePendingChanged = { pendingValues.append($0) }

        sdk.start()
        sdk.stop()

        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertTrue(pendingValues.isEmpty)
    }

    func testAbsenceFinalizeDoesNotSetStopFinalizePending() async {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let clock = MutableClock()
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SDKTestFixture.makeSDK(
            engine: engine,
            queue: { _ in queue },
            clock: clock,
            absenceScheduler: absenceScheduler
        )
        var pendingValues: [Bool] = []
        sdk.onSelectStopFinalizePendingChanged = { pendingValues.append($0) }

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        SDKTestFixture.closeOpenWindows(clock: clock, absenceScheduler: absenceScheduler)
        await queue.waitForWriteStart()

        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertTrue(pendingValues.isEmpty)

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        XCTAssertFalse(sdk.selectIsStopFinalizePending)
    }

    func testStopFinalizePendingClearsOnWriteFailure() async {
        let engine = FakeEngine()
        let clock = MutableClock()
        let absenceScheduler = ManualDelayedActionScheduler()
        let sdk = SelectBeaconSDK(
            engine: { engine },
            permissionObserver: { FakePermissionObserver(authorization: .always) },
            lifecycleObserver: { FakeLifecycleObserver(isActive: true) },
            clock: clock,
            queue: { _ in FailingQueue() },
            networkPathObserver: { FakeNetworkPathObserver() },
            absenceExpiryScheduler: absenceScheduler,
            identity: AppIdentity(appKey: "customer-key", appSecret: "test-secret")
        )
        let becamePending = expectation(description: "Pending true")
        let cleared = expectation(description: "Pending false after failure")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            if pending {
                becamePending.fulfill()
            } else {
                cleared.fulfill()
            }
        }

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        sdk.stop()

        await fulfillment(of: [becamePending, cleared], timeout: 1)
        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(sdk.operationalStatus, .degraded(.durableQueueWriteFailed))
    }

    func testSecondStopWithoutWindowsKeepsFinalizePendingUntilInFlightWriteSettles() async {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = SDKTestFixture.makeSDK(engine: engine, queue: { _ in queue })
        var pendingValues: [Bool] = []
        let cleared = expectation(description: "Pending clears after in-flight write settles")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            pendingValues.append(pending)
            if !pending {
                cleared.fulfill()
            }
        }

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        sdk.stop()
        await queue.waitForWriteStart()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true])

        // Empty second stop must not unlock Start while the chained finalize
        // write is still inside the queue actor.
        sdk.stop()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true])

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [cleared], timeout: 1)
        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true, false])
    }

    func testMultiWindowRepeatedStopPersistsAllReports() async throws {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = SDKTestFixture.makeSDK(engine: engine, queue: { _ in queue })
        let cleared = expectation(description: "Pending clears after full batch")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            if !pending {
                cleared.fulfill()
            }
        }

        sdk.start()
        engine.emit([
            SDKTestFixture.beacon(minor: 1),
            SDKTestFixture.beacon(minor: 2),
        ])
        sdk.stop()
        await queue.waitForWriteStart()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)

        // Empty second stop while the first durable write is still blocked.
        sdk.stop()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        let midBatch = try await queue.nextBatch(limit: 10)
        XCTAssertTrue(midBatch.isEmpty)

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        // Full stop-finalize batch has not finished; Start must stay gated.
        XCTAssertTrue(sdk.selectIsStopFinalizePending)

        await queue.waitForWriteStart()
        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [cleared], timeout: 1)

        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        let queued = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(Set(queued.map(\.minor)), Set([1, 2]))
    }

    func testStopFinalizePendingReplacedByOverlappingStopGeneration() async throws {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = SDKTestFixture.makeSDK(engine: engine, queue: { _ in queue })
        var pendingValues: [Bool] = []
        let cleared = expectation(description: "Pending clears after replacement generation")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            pendingValues.append(pending)
            if !pending {
                cleared.fulfill()
            }
        }

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        sdk.stop()
        await queue.waitForWriteStart()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true])

        // Immediate restart keeps the first finalize pending, then a new open
        // window + stop replaces the generation without a false blip.
        sdk.start()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        engine.emit([SDKTestFixture.beacon(minor: 43, rssi: -60)])
        sdk.stop()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true])
        XCTAssertTrue(sdk.selectOpenWindowSnapshots.isEmpty)

        // Writes are chained, not concurrent: release the first write, then wait
        // for the second write to start before releasing it.
        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true])

        await queue.waitForWriteStart()
        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
        await fulfillment(of: [cleared], timeout: 1)
        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(pendingValues, [true, false])

        let queued = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(queued.map(\.minor), [42, 43])
    }

    func testClearPendingReportsEmptiesQueueWhenStopped() async throws {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let sdk = SDKTestFixture.makeSDK(engine: engine, queue: { _ in queue })
        let emptied = expectation(description: "Pending snapshot emptied")
        sdk.onSelectPendingReportsChanged = { reports in
            if reports.isEmpty {
                emptied.fulfill()
            }
        }

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        sdk.stop()
        await SDKTestFixture.waitForQueueCount(queue, minCount: 1)
        XCTAssertEqual(queue.records.count, 1)

        try await sdk.selectClearPendingReports()
        await fulfillment(of: [emptied], timeout: 1)
        XCTAssertTrue(queue.records.isEmpty)
        let pending = try await sdk.selectPendingReports()
        XCTAssertTrue(pending.isEmpty)
    }

    func testClearPendingReportsRefusesWhileDetectionActive() async throws {
        let engine = FakeEngine()
        let queue = InMemoryQueue()
        let sdk = SDKTestFixture.makeSDK(engine: engine, queue: { _ in queue })
        sdk.start()

        do {
            try await sdk.selectClearPendingReports()
            XCTFail("Expected clear to refuse while detection is active")
        } catch let error as SelectPendingReportsClearError {
            XCTAssertEqual(error, .detectionActive)
        }
    }

    func testClearPendingReportsRefusesWhileStopFinalizePending() async throws {
        let engine = FakeEngine()
        let queue = BlockingQueue()
        let sdk = SDKTestFixture.makeSDK(engine: engine, queue: { _ in queue })

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        sdk.stop()
        await queue.waitForWriteStart()
        XCTAssertTrue(sdk.selectIsStopFinalizePending)

        do {
            try await sdk.selectClearPendingReports()
            XCTFail("Expected clear to refuse while stop finalize is pending")
        } catch let error as SelectPendingReportsClearError {
            XCTAssertEqual(error, .stopFinalizePending)
        }

        await queue.releaseNextWrite()
        await queue.waitForWriteCompletion()
    }

    func testClearPendingReportsRecoversUnreadableQueue() async throws {
        let engine = FakeEngine()
        let queue = UnreadableQueue()
        let sdk = SDKTestFixture.makeSDK(engine: engine, queue: { _ in queue })
        let clearedFinalize = expectation(description: "Stop finalize settled")
        sdk.onSelectStopFinalizePendingChanged = { pending in
            if !pending {
                clearedFinalize.fulfill()
            }
        }

        sdk.start()
        engine.emit([SDKTestFixture.beacon(minor: 42)])
        sdk.stop()
        await fulfillment(of: [clearedFinalize], timeout: 1)

        XCTAssertFalse(sdk.selectIsStopFinalizePending)
        XCTAssertEqual(sdk.operationalStatus, .degraded(.durableQueueUnreadable))

        try await sdk.selectClearPendingReports()
        XCTAssertEqual(sdk.operationalStatus, .ready)
        let pending = try await sdk.selectPendingReports()
        XCTAssertTrue(pending.isEmpty)
    }
}
