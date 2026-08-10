import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

@MainActor
final class UploadCoordinatorTests: XCTestCase {
    final class FakeAuthProvider: AuthProvider {
        private(set) var tokenCallCount = 0
        private(set) var invalidateCount = 0
        var token = "batch-token"
        var error: Error?
        var errorOnCalls: Set<Int> = []

        func validAuthorization() async throws -> UploadAuthorization {
            tokenCallCount += 1
            // When `errorOnCalls` is set, only those call indices throw.
            if !errorOnCalls.isEmpty {
                if errorOnCalls.contains(tokenCallCount) {
                    throw error ?? TokenBrokerAuthError.networkRequestFailed
                }
                return UploadAuthorization(accessToken: token)
            }
            if let error {
                throw error
            }
            return UploadAuthorization(accessToken: token)
        }

        func invalidateCachedToken() {
            invalidateCount += 1
        }
    }

    final class FakeTransport: UploadTransport {
        struct UploadError: Error {}

        private(set) var uploads: [[QueuedDetection]] = []
        private(set) var tokens: [String] = []
        var shouldFail = false
        var statusErrors: [HTTPIngestUploadError] = []
        var acknowledgeAll = true

        func upload(
            detections: [QueuedDetection],
            authorization: UploadAuthorization
        ) async throws -> UploadResponse {
            uploads.append(detections)
            tokens.append(authorization.accessToken)
            if !statusErrors.isEmpty {
                throw statusErrors.removeFirst()
            }
            if shouldFail {
                throw UploadError()
            }
            let ids = acknowledgeAll ? detections.map(\.id) : []
            return .accepted(acknowledgedIDs: ids)
        }
    }

    private let fleetUUID = SDKConfiguration.default.monitoredUUIDs[0]
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeDetection(minor: Int = 42, queuedAt: Date? = nil) -> QueuedDetection {
        QueuedDetectionFixtures.make(minor: minor, latestTimestamp: queuedAt ?? t0, queuedAt: queuedAt ?? t0)
    }

    private func makeCoordinator(
        queue: InMemoryQueue,
        auth: FakeAuthProvider = FakeAuthProvider(),
        transport: FakeTransport = FakeTransport(),
        path: FakeNetworkPathObserver = FakeNetworkPathObserver(),
        quiet: ManualDelayedActionScheduler = ManualDelayedActionScheduler(),
        maxAge: ManualDelayedActionScheduler = ManualDelayedActionScheduler(),
        retry: ManualDelayedActionScheduler = ManualDelayedActionScheduler(),
        clock: MutableClock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000)),
        diagnostics: FakeDiagnosticsReporter = FakeDiagnosticsReporter(),
        deviceIdentifier: FakeDeviceIdentifier = FakeDeviceIdentifier(),
        configuration: SDKConfiguration = .default,
        onQueueAcknowledged: (@MainActor () async -> Void)? = nil,
        onHostVisibleAuthenticationFailure: (@MainActor () -> Void)? = nil,
        onAuthenticationRecovered: (@MainActor () -> Void)? = nil
    ) -> (
        UploadCoordinator,
        FakeAuthProvider,
        FakeTransport,
        FakeNetworkPathObserver,
        ManualDelayedActionScheduler,
        ManualDelayedActionScheduler,
        ManualDelayedActionScheduler,
        MutableClock,
        FakeDiagnosticsReporter
    ) {
        let coordinator = UploadCoordinator(
            configuration: configuration,
            queueProvider: { queue },
            authProvider: auth,
            transport: transport,
            pathObserver: path,
            quietDebounceScheduler: quiet,
            maxAgeScheduler: maxAge,
            retryBackoffScheduler: retry,
            clock: clock,
            diagnosticsReporter: diagnostics,
            deviceIdentifier: deviceIdentifier,
            onQueueAcknowledged: onQueueAcknowledged,
            onHostVisibleAuthenticationFailure: onHostVisibleAuthenticationFailure,
            onAuthenticationRecovered: onAuthenticationRecovered
        )
        return (coordinator, auth, transport, path, quiet, maxAge, retry, clock, diagnostics)
    }

    private func waitForFlush(
        queue: InMemoryQueue,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !queue.records.isEmpty,
              DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if !queue.records.isEmpty {
            XCTFail(
                "Timed out waiting for upload; \(queue.records.count) record(s) remain",
                file: file,
                line: line
            )
        }
    }

    private func waitForSchedules(
        _ count: Int,
        scheduler: ManualDelayedActionScheduler,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while scheduler.scheduledDelays.count < count,
              DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if scheduler.scheduledDelays.count < count {
            XCTFail(
                "Timed out waiting for \(count) schedules; got \(scheduler.scheduledDelays)",
                file: file,
                line: line
            )
        }
    }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if !condition() {
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
        }
    }

    func testQuietDebounceFlushesBatchWithOneToken() async {
        let first = makeDetection(minor: 1)
        let second = makeDetection(minor: 2)
        let queue = InMemoryQueue(records: [first, second])
        let (coordinator, auth, transport, _, quiet, _, _, _, _) = makeCoordinator(queue: queue)

        coordinator.start()
        coordinator.setForeground(true)
        coordinator.noteSightingActivity()
        XCTAssertEqual(quiet.scheduledDelays.last, SDKConfiguration.default.sendDebounce)

        quiet.fire()
        await waitForFlush(queue: queue)

        XCTAssertEqual(auth.tokenCallCount, 1)
        XCTAssertEqual(transport.uploads.count, 1)
        XCTAssertEqual(transport.uploads.first?.map(\.minor), [1, 2])
        XCTAssertEqual(transport.tokens, ["batch-token"])
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testSightingActivityResetsQuietDebounce() {
        let queue = InMemoryQueue(records: [makeDetection()])
        let (coordinator, _, _, _, quiet, _, _, _, _) = makeCoordinator(queue: queue)

        coordinator.start()
        coordinator.setForeground(true)
        coordinator.noteSightingActivity()
        XCTAssertEqual(quiet.scheduledDelays.count, 1)
        coordinator.noteSightingActivity()
        XCTAssertEqual(quiet.scheduledDelays.count, 2)
        XCTAssertEqual(
            quiet.scheduledDelays,
            [
                SDKConfiguration.default.sendDebounce,
                SDKConfiguration.default.sendDebounce,
            ]
        )
    }

    func testBackgroundSightingDoesNotScheduleQuietDebounce() {
        let queue = InMemoryQueue(records: [makeDetection()])
        let (coordinator, _, _, _, quiet, _, _, _, _) = makeCoordinator(queue: queue)

        coordinator.start()
        coordinator.setForeground(false)
        coordinator.noteSightingActivity()
        XCTAssertTrue(quiet.scheduledDelays.isEmpty)
        XCTAssertFalse(quiet.hasPendingAction)
    }

    func testQueueChangedSchedulesMaxAgeFromOldestQueuedAt() async {
        let queuedAt = t0
        let queue = InMemoryQueue(records: [makeDetection(queuedAt: queuedAt)])
        let clock = MutableClock(now: t0.addingTimeInterval(100))
        let (coordinator, _, _, _, _, maxAge, _, _, _) = makeCoordinator(
            queue: queue,
            clock: clock
        )

        coordinator.start()
        await coordinator.noteQueueChanged()

        // maxQueueAge 300 - already waited 100 => delay 200
        XCTAssertEqual(maxAge.scheduledDelays.last, 200)
    }

    func testStartRestoresMaxAgeScheduleForExistingBacklog() async {
        let queue = InMemoryQueue(records: [makeDetection(queuedAt: t0)])
        let clock = MutableClock(now: t0.addingTimeInterval(100))
        let (coordinator, _, _, _, _, maxAge, _, _, _) = makeCoordinator(
            queue: queue,
            clock: clock
        )

        coordinator.start()
        await waitForSchedules(1, scheduler: maxAge)

        XCTAssertEqual(maxAge.scheduledDelays, [200])
    }

    func testMaxQueueAgeForcesFlushWhileNeverQuiet() async {
        let queue = InMemoryQueue(records: [makeDetection(queuedAt: t0)])
        let clock = MutableClock(now: t0)
        let (coordinator, auth, transport, _, quiet, maxAge, _, _, _) = makeCoordinator(
            queue: queue,
            clock: clock
        )

        coordinator.start()
        coordinator.setForeground(true)
        // Continuous sightings keep resetting quiet debounce.
        coordinator.noteSightingActivity()
        await coordinator.noteQueueChanged()

        XCTAssertEqual(quiet.scheduledDelays.last, SDKConfiguration.default.sendDebounce)
        XCTAssertEqual(maxAge.scheduledDelays.last, SDKConfiguration.default.maxQueueAge)

        // More sightings: quiet resets, max-age still pending from schedule.
        coordinator.noteSightingActivity()
        XCTAssertEqual(quiet.scheduledDelays.count, 2)

        maxAge.fire()
        await waitForFlush(queue: queue)

        XCTAssertEqual(auth.tokenCallCount, 1)
        XCTAssertEqual(transport.uploads.count, 1)
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testOpportunisticFlushOnBackgroundAndForeground() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 7)])
        let (coordinator, auth, transport, _, quiet, _, _, _, _) = makeCoordinator(queue: queue)

        coordinator.start()
        coordinator.setForeground(true)
        coordinator.noteSightingActivity()
        XCTAssertTrue(quiet.hasPendingAction)

        coordinator.setForeground(false)
        coordinator.flushOpportunistically()
        await waitForFlush(queue: queue)

        XCTAssertFalse(quiet.hasPendingAction)
        XCTAssertEqual(auth.tokenCallCount, 1)
        XCTAssertEqual(transport.uploads.first?.map(\.minor), [7])

        let queue2 = InMemoryQueue(records: [makeDetection(minor: 8)])
        let (coordinator2, auth2, transport2, _, _, _, _, _, _) = makeCoordinator(queue: queue2)
        coordinator2.start()
        coordinator2.setForeground(false)
        coordinator2.setForeground(true)
        coordinator2.flushOpportunistically()
        await waitForFlush(queue: queue2)
        XCTAssertEqual(auth2.tokenCallCount, 1)
        XCTAssertEqual(transport2.uploads.first?.map(\.minor), [8])
    }

    func testOfflineTriggerDoesNotSendOrScheduleBackoff() async {
        let queue = InMemoryQueue(records: [makeDetection()])
        let path = FakeNetworkPathObserver(isSatisfied: false)
        let (coordinator, auth, transport, _, quiet, _, retry, _, _) = makeCoordinator(
            queue: queue,
            path: path
        )

        coordinator.start()
        coordinator.setForeground(true)
        coordinator.noteSightingActivity()
        quiet.fire()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(auth.tokenCallCount, 0)
        XCTAssertTrue(transport.uploads.isEmpty)
        XCTAssertEqual(queue.records.count, 1)
        XCTAssertTrue(retry.scheduledDelays.isEmpty)
    }

    func testConnectivityReturnFlushesImmediately() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 3)])
        let path = FakeNetworkPathObserver(isSatisfied: false)
        let (coordinator, auth, transport, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            path: path
        )

        coordinator.start()
        path.setSatisfied(true)
        await waitForFlush(queue: queue)

        XCTAssertEqual(auth.tokenCallCount, 1)
        XCTAssertEqual(transport.uploads.first?.map(\.minor), [3])
    }

    func testStopStartRearmsPathObservationAndConnectivityFlush() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 4)])
        let path = FakeNetworkPathObserver(isSatisfied: false)
        let (coordinator, _, transport, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            path: path
        )

        coordinator.start()
        coordinator.stop()
        coordinator.start()
        path.setSatisfied(true)
        await waitForFlush(queue: queue)

        XCTAssertEqual(path.startCount, 2)
        XCTAssertEqual(path.stopCount, 1)
        XCTAssertEqual(transport.uploads.first?.map(\.minor), [4])
    }

    func testFailedUploadRetainsQueueAndReportsDiagnostics() async {
        let queue = InMemoryQueue(records: [makeDetection()])
        let transport = FakeTransport()
        transport.shouldFail = true
        let diagnostics = FakeDiagnosticsReporter()
        let (coordinator, _, _, _, _, _, retry, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            diagnostics: diagnostics
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(queue.records.count, 1)
        XCTAssertEqual(diagnostics.events, [.uploadFailed])
        XCTAssertEqual(retry.scheduledDelays.last, SDKConfiguration.default.uploadRetryBackoff)
    }

    func testRateLimitedUploadHonorsRetryAfterWithoutAdvancingBackoff() async {
        let queue = InMemoryQueue(records: [makeDetection()])
        let transport = FakeTransport()
        transport.statusErrors = [.rateLimited(retryAfter: 90)]
        let retry = ManualDelayedActionScheduler()
        let quiet = ManualDelayedActionScheduler()
        let (coordinator, _, _, _, _, _, _, clock, diagnostics) = makeCoordinator(
            queue: queue,
            transport: transport,
            quiet: quiet,
            retry: retry
        )

        coordinator.start()
        coordinator.setForeground(true)
        coordinator.flushOpportunistically()
        await waitForSchedules(1, scheduler: retry)

        XCTAssertEqual(queue.records.count, 1)
        XCTAssertEqual(diagnostics.events, [.uploadFailed])
        XCTAssertEqual(retry.scheduledDelays, [90])
        XCTAssertEqual(transport.uploads.count, 1)

        // Opportunistic / quiet triggers must not bypass the pause.
        let schedulesAfterRateLimit = retry.scheduledDelays.count
        coordinator.flushOpportunistically()
        await waitForSchedules(schedulesAfterRateLimit + 1, scheduler: retry)
        coordinator.noteSightingActivity()
        XCTAssertFalse(quiet.hasPendingAction)
        XCTAssertEqual(transport.uploads.count, 1)
        XCTAssertEqual(retry.scheduledDelays.last, 90)

        // After Retry-After elapses, exponential backoff stays at the initial 15s on a later generic failure.
        let schedulesBeforeResume = retry.scheduledDelays.count
        clock.now = clock.now.addingTimeInterval(90)
        transport.statusErrors = []
        transport.shouldFail = true
        retry.fire()
        await waitForSchedules(schedulesBeforeResume + 1, scheduler: retry)
        XCTAssertEqual(retry.scheduledDelays.last, SDKConfiguration.default.uploadRetryBackoff)
        XCTAssertEqual(transport.uploads.count, 2)
    }

    func testRetryBackoffDoublesAndCapsAtMaximum() async {
        let queue = InMemoryQueue(records: [makeDetection()])
        let transport = FakeTransport()
        transport.shouldFail = true
        let retry = ManualDelayedActionScheduler()
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            retry: retry
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        let expected: [TimeInterval] = [15, 30, 60, 120, 240, 300, 300]
        for index in expected.indices {
            await waitForSchedules(index + 1, scheduler: retry)
            XCTAssertEqual(retry.scheduledDelays[index], expected[index])
            if index < expected.count - 1 {
                retry.fire()
            }
        }

        XCTAssertEqual(queue.records.count, 1)
    }

    func testNoteQueueChangedDoesNotScheduleQuietDebounce() async {
        let queue = InMemoryQueue(records: [makeDetection()])
        let (coordinator, _, _, _, quiet, maxAge, _, _, _) = makeCoordinator(queue: queue)

        coordinator.start()
        coordinator.setForeground(true)
        await coordinator.noteQueueChanged()

        XCTAssertTrue(quiet.scheduledDelays.isEmpty)
        XCTAssertEqual(maxAge.scheduledDelays.last, SDKConfiguration.default.maxQueueAge)
    }

    func testAcknowledgeInvokesQueueAcknowledgedCallback() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 9)])
        var ackCount = 0
        let coordinator = UploadCoordinator(
            configuration: .default,
            queueProvider: { queue },
            authProvider: FakeAuthProvider(),
            transport: FakeTransport(),
            pathObserver: FakeNetworkPathObserver(),
            quietDebounceScheduler: ManualDelayedActionScheduler(),
            maxAgeScheduler: ManualDelayedActionScheduler(),
            retryBackoffScheduler: ManualDelayedActionScheduler(),
            clock: MutableClock(now: t0),
            deviceIdentifier: FakeDeviceIdentifier(),
            onQueueAcknowledged: { ackCount += 1 }
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForFlush(queue: queue)

        XCTAssertEqual(ackCount, 1)
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testEmptyAcknowledgementStopsFlushWithoutSpinning() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 11)])
        let transport = FakeTransport()
        transport.acknowledgeAll = false
        let retry = ManualDelayedActionScheduler()
        let diagnostics = FakeDiagnosticsReporter()
        var ackCount = 0
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            retry: retry,
            diagnostics: diagnostics,
            onQueueAcknowledged: { ackCount += 1 }
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(transport.uploads.count, 1)
        XCTAssertEqual(queue.records.count, 1)
        XCTAssertEqual(ackCount, 0)
        XCTAssertEqual(diagnostics.events, [.uploadFailed])
        XCTAssertEqual(retry.scheduledDelays.last, SDKConfiguration.default.uploadRetryBackoff)
    }

    func testMultiBatchFlushInvokesAcknowledgementCallbackPerBatch() async {
        let queue = InMemoryQueue(records: [
            makeDetection(minor: 1),
            makeDetection(minor: 2),
        ])
        let configuration = SDKConfiguration.default.with(uploadBatchLimit: 1)
        var ackCount = 0
        let (coordinator, _, transport, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            configuration: configuration,
            onQueueAcknowledged: { ackCount += 1 }
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForFlush(queue: queue)
        await waitUntil("two acknowledgement callbacks") { ackCount == 2 }

        XCTAssertEqual(transport.uploads.count, 2)
        XCTAssertEqual(ackCount, 2)
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testMissingDeviceIdentifierSkipsUploadAndSchedulesRetry() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 5)])
        let transport = FakeTransport()
        let retry = ManualDelayedActionScheduler()
        let diagnostics = FakeDiagnosticsReporter()
        let (coordinator, auth, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            retry: retry,
            diagnostics: diagnostics,
            deviceIdentifier: FakeDeviceIdentifier(deviceId: nil)
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(transport.uploads.count, 0)
        XCTAssertEqual(auth.tokenCallCount, 0)
        XCTAssertEqual(queue.records.count, 1)
        XCTAssertEqual(diagnostics.events, [.deviceIdentifierUnavailable])
        XCTAssertEqual(retry.scheduledDelays.last, SDKConfiguration.default.uploadRetryBackoff)
    }

    func testClientErrorDeadLettersAndAdvancesFIFO() async {
        let poison = makeDetection(minor: 1)
        let healthy = makeDetection(minor: 2)
        let queue = InMemoryQueue(records: [poison, healthy])
        let transport = FakeTransport()
        transport.statusErrors = [.clientError(statusCode: 400)]
        let diagnostics = FakeDiagnosticsReporter()
        let configuration = SDKConfiguration.default.with(uploadBatchLimit: 1)
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            diagnostics: diagnostics,
            configuration: configuration
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForFlush(queue: queue)

        XCTAssertEqual(queue.deadLetters.map(\.minor), [1])
        XCTAssertTrue(queue.records.isEmpty)
        XCTAssertEqual(transport.uploads.count, 2)
        XCTAssertTrue(diagnostics.events.contains(.uploadDeadLettered))
    }

    func testServerErrorRetriesUntilMaxAttemptsThenDeadLetters() async {
        let configuration = SDKConfiguration.default.with(maxUploadAttempts: 2)
        let queue = InMemoryQueue(records: [makeDetection(minor: 3)])
        let transport = FakeTransport()
        transport.statusErrors = [
            .serverError(statusCode: 500),
            .serverError(statusCode: 500),
        ]
        let retry = ManualDelayedActionScheduler()
        let diagnostics = FakeDiagnosticsReporter()
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            retry: retry,
            diagnostics: diagnostics,
            configuration: configuration
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForSchedules(1, scheduler: retry)
        XCTAssertEqual(queue.records.first?.uploadAttemptCount, 1)
        XCTAssertTrue(queue.deadLetters.isEmpty)

        retry.fire()
        await waitUntil("dead-lettered after max attempts") {
            !queue.deadLetters.isEmpty
        }
        XCTAssertTrue(queue.records.isEmpty)
        XCTAssertEqual(queue.deadLetters.map(\.minor), [3])
        XCTAssertTrue(diagnostics.events.contains(.uploadDeadLettered))
    }

    func testUnauthorizedRefreshesTokenAndRetriesBatch() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 4)])
        let transport = FakeTransport()
        transport.statusErrors = [.unauthorized(statusCode: 401)]
        let auth = FakeAuthProvider()
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            auth: auth,
            transport: transport
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForFlush(queue: queue)

        XCTAssertEqual(auth.invalidateCount, 1)
        XCTAssertEqual(auth.tokenCallCount, 2)
        XCTAssertEqual(transport.uploads.count, 2)
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testUnauthorizedAfterRefreshSchedulesBackoff() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 5)])
        let transport = FakeTransport()
        transport.statusErrors = [
            .unauthorized(statusCode: 401),
            .unauthorized(statusCode: 401),
        ]
        let auth = FakeAuthProvider()
        let retry = ManualDelayedActionScheduler()
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            auth: auth,
            transport: transport,
            retry: retry
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForSchedules(1, scheduler: retry)

        XCTAssertEqual(auth.invalidateCount, 1)
        XCTAssertEqual(auth.tokenCallCount, 2)
        XCTAssertEqual(transport.uploads.count, 2)
        XCTAssertEqual(queue.records.count, 1)
        XCTAssertEqual(retry.scheduledDelays.last, SDKConfiguration.default.uploadRetryBackoff)
    }

    func testRateLimitedWithoutRetryAfterUsesExponentialBackoff() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 6)])
        let transport = FakeTransport()
        transport.statusErrors = [.rateLimited(retryAfter: nil)]
        let retry = ManualDelayedActionScheduler()
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            retry: retry
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForSchedules(1, scheduler: retry)
        XCTAssertEqual(retry.scheduledDelays.last, SDKConfiguration.default.uploadRetryBackoff)
        XCTAssertEqual(queue.records.count, 1)
    }

    func testBackgroundWakeFlushesWhenOnline() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 8)])
        let transport = FakeTransport()
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport
        )

        coordinator.start()
        coordinator.setForeground(false)
        await coordinator.noteQueueChanged()
        await waitForFlush(queue: queue)

        XCTAssertEqual(transport.uploads.count, 1)
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testBackgroundWakeDoesNotFlushWhenOffline() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 9)])
        let path = FakeNetworkPathObserver(isSatisfied: false)
        let transport = FakeTransport()
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            path: path
        )

        coordinator.start()
        coordinator.setForeground(false)
        await coordinator.noteQueueChanged()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(transport.uploads.isEmpty)
        XCTAssertEqual(queue.records.count, 1)
    }

    func testBackgroundWakeFlushIsBoundedToOneBatch() async {
        let queue = InMemoryQueue(records: [
            makeDetection(minor: 1),
            makeDetection(minor: 2),
            makeDetection(minor: 3),
        ])
        let transport = FakeTransport()
        let configuration = SDKConfiguration.default.with(uploadBatchLimit: 1)
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            configuration: configuration
        )

        coordinator.start()
        coordinator.setForeground(false)
        await coordinator.noteQueueChanged()
        await waitUntil("one bounded batch uploaded") { transport.uploads.count == 1 }

        XCTAssertEqual(transport.uploads.count, 1)
        XCTAssertEqual(transport.uploads.first?.map(\.minor), [1])
        XCTAssertEqual(queue.records.map(\.minor), [2, 3])
    }

    func testFlushAgainRunsOnceAfterInFlightFlush() async {
        let first = makeDetection(minor: 10)
        let second = makeDetection(minor: 11)
        let queue = InMemoryQueue(records: [first])
        let transport = FakeTransport()
        let configuration = SDKConfiguration.default.with(uploadBatchLimit: 1)
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            configuration: configuration
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        queue.records.append(second)
        coordinator.flushOpportunistically()
        await waitForFlush(queue: queue)
        await waitUntil("both batches uploaded") { transport.uploads.count >= 2 }

        XCTAssertEqual(transport.uploads.count, 2)
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testTokenFetchFailureUsesBackoffWithoutInvalidate() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 12)])
        let auth = FakeAuthProvider()
        auth.error = TokenBrokerAuthError.networkRequestFailed
        let transport = FakeTransport()
        let retry = ManualDelayedActionScheduler()
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            auth: auth,
            transport: transport,
            retry: retry
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForSchedules(1, scheduler: retry)

        XCTAssertEqual(auth.invalidateCount, 0)
        XCTAssertTrue(transport.uploads.isEmpty)
        XCTAssertEqual(retry.scheduledDelays.last, SDKConfiguration.default.uploadRetryBackoff)
    }

    func testUnauthorizedAuthNotifiesHostAndRecoversOnLaterSuccess() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 20)])
        let auth = FakeAuthProvider()
        auth.error = TokenBrokerAuthError.unauthorized(statusCode: 401)
        let transport = FakeTransport()
        let retry = ManualDelayedActionScheduler()
        let diagnostics = FakeDiagnosticsReporter()
        var failureCount = 0
        var recoverCount = 0
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            auth: auth,
            transport: transport,
            retry: retry,
            diagnostics: diagnostics,
            onHostVisibleAuthenticationFailure: { failureCount += 1 },
            onAuthenticationRecovered: { recoverCount += 1 }
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForSchedules(1, scheduler: retry)

        XCTAssertEqual(failureCount, 1)
        XCTAssertEqual(recoverCount, 0)
        XCTAssertEqual(queue.records.count, 1)
        XCTAssertEqual(diagnostics.events, [.uploadFailed])
        XCTAssertEqual(diagnostics.errors.first as? DiagnosticNotice, DiagnosticNotice("tokenBroker"))

        auth.error = nil
        retry.fire()
        await waitForFlush(queue: queue)

        XCTAssertEqual(recoverCount, 1)
        XCTAssertTrue(queue.records.isEmpty)
        XCTAssertEqual(transport.uploads.count, 1)
    }

    func testNetworkAuthFailureDoesNotNotifyHostVisibleAuthentication() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 21)])
        let auth = FakeAuthProvider()
        auth.error = TokenBrokerAuthError.networkRequestFailed
        let retry = ManualDelayedActionScheduler()
        var failureCount = 0
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            auth: auth,
            retry: retry,
            onHostVisibleAuthenticationFailure: { failureCount += 1 }
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForSchedules(1, scheduler: retry)

        XCTAssertEqual(failureCount, 0)
    }

    func testIngestUnauthorizedThenSuccessfulRefreshDoesNotNotifyHost() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 22)])
        let transport = FakeTransport()
        transport.statusErrors = [.unauthorized(statusCode: 401)]
        var failureCount = 0
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            transport: transport,
            onHostVisibleAuthenticationFailure: { failureCount += 1 }
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForFlush(queue: queue)

        XCTAssertEqual(failureCount, 0)
        XCTAssertTrue(queue.records.isEmpty)
    }

    func testIngestUnauthorizedAndRefreshBrokerUnauthorizedNotifiesHost() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 23)])
        let transport = FakeTransport()
        transport.statusErrors = [.unauthorized(statusCode: 401)]
        let auth = FakeAuthProvider()
        // First mint succeeds; refresh after ingest 401 fails host-visibly.
        auth.error = TokenBrokerAuthError.unauthorized(statusCode: 403)
        auth.errorOnCalls = [2]
        let retry = ManualDelayedActionScheduler()
        let diagnostics = FakeDiagnosticsReporter()
        var failureCount = 0
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            auth: auth,
            transport: transport,
            retry: retry,
            diagnostics: diagnostics,
            onHostVisibleAuthenticationFailure: { failureCount += 1 }
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForSchedules(1, scheduler: retry)

        XCTAssertEqual(failureCount, 1)
        XCTAssertEqual(queue.records.count, 1)
        XCTAssertEqual(diagnostics.errors.last as? DiagnosticNotice, DiagnosticNotice("tokenBroker"))
    }

    func testAuthRateLimitedHonorsRetryAfterWithoutAdvancingBackoff() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 13)])
        let auth = FakeAuthProvider()
        auth.error = TokenBrokerAuthError.rateLimited(retryAfter: 75)
        let transport = FakeTransport()
        let retry = ManualDelayedActionScheduler()
        let (coordinator, _, _, _, _, _, _, clock, _) = makeCoordinator(
            queue: queue,
            auth: auth,
            transport: transport,
            retry: retry
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForSchedules(1, scheduler: retry)

        XCTAssertEqual(auth.invalidateCount, 0)
        XCTAssertTrue(transport.uploads.isEmpty)
        XCTAssertEqual(retry.scheduledDelays.last, 75)

        // After Retry-After elapses, a generic auth failure still uses the initial 15s backoff.
        let schedulesBeforeResume = retry.scheduledDelays.count
        clock.now = clock.now.addingTimeInterval(75)
        auth.error = TokenBrokerAuthError.networkRequestFailed
        retry.fire()
        await waitForSchedules(schedulesBeforeResume + 1, scheduler: retry)

        XCTAssertEqual(retry.scheduledDelays.last, SDKConfiguration.default.uploadRetryBackoff)
    }

    func testAuthRateLimitedWithoutRetryAfterUsesExponentialBackoff() async {
        let queue = InMemoryQueue(records: [makeDetection(minor: 14)])
        let auth = FakeAuthProvider()
        auth.error = TokenBrokerAuthError.rateLimited(retryAfter: nil)
        let transport = FakeTransport()
        let retry = ManualDelayedActionScheduler()
        let (coordinator, _, _, _, _, _, _, _, _) = makeCoordinator(
            queue: queue,
            auth: auth,
            transport: transport,
            retry: retry
        )

        coordinator.start()
        coordinator.flushOpportunistically()
        await waitForSchedules(1, scheduler: retry)

        XCTAssertTrue(transport.uploads.isEmpty)
        XCTAssertEqual(retry.scheduledDelays.last, SDKConfiguration.default.uploadRetryBackoff)
    }
}
