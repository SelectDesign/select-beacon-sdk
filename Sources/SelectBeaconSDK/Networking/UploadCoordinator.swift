import Foundation

/// Transmits durable queued reports (the forward half of store-and-forward).
///
/// Capture enqueues first; this type only decides when to attempt network
/// delivery under the connectivity-gated trigger set documented in
/// `docs/architecture.md` §5b.
@MainActor
final class UploadCoordinator {
    private let configuration: SDKConfiguration
    private let queueProvider: () -> (any DurableDetectionQueue)?
    private var authProvider: AuthProvider
    private var transport: UploadTransport
    private let pathObserver: NetworkPathObserving
    private let quietDebounceScheduler: DelayedActionScheduling
    private let maxAgeScheduler: DelayedActionScheduling
    private let retryBackoffScheduler: DelayedActionScheduling
    private let clock: Clock
    private let diagnosticsReporter: DiagnosticsReporting
    private let deviceIdentifier: DeviceIdentifying
    private let onQueueAcknowledged: (@MainActor () async -> Void)?
    private let onHostVisibleAuthenticationFailure: (@MainActor () -> Void)?
    private let onAuthenticationRecovered: (@MainActor () -> Void)?

    private var wantsRunning = false
    private var isForeground = true
    private var isFlushing = false
    private var flushAgain = false
    /// Bumped in `stop()` so an in-flight flush cannot mutate the queue after stop/clear.
    private var flushGeneration = 0
    private var flushIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentBackoff: TimeInterval
    /// When set, flushes wait until this instant (e.g. API `Retry-After`).
    private var uploadPausedUntil: Date?

    /// Returned when the transport accepts a batch but acknowledges no queued IDs.
    struct NoOpUploadAcknowledgement: Error {}

    init(
        configuration: SDKConfiguration = .default,
        queueProvider: @escaping () -> (any DurableDetectionQueue)?,
        authProvider: AuthProvider,
        transport: UploadTransport,
        pathObserver: NetworkPathObserving,
        quietDebounceScheduler: DelayedActionScheduling = TaskDelayedActionScheduler(),
        maxAgeScheduler: DelayedActionScheduling = TaskDelayedActionScheduler(),
        retryBackoffScheduler: DelayedActionScheduling = TaskDelayedActionScheduler(),
        clock: Clock,
        diagnosticsReporter: DiagnosticsReporting = NoopDiagnosticsReporter(),
        deviceIdentifier: DeviceIdentifying = VendorDeviceIdentifier(),
        onQueueAcknowledged: (@MainActor () async -> Void)? = nil,
        onHostVisibleAuthenticationFailure: (@MainActor () -> Void)? = nil,
        onAuthenticationRecovered: (@MainActor () -> Void)? = nil
    ) {
        self.configuration = configuration
        self.queueProvider = queueProvider
        self.authProvider = authProvider
        self.transport = transport
        self.pathObserver = pathObserver
        self.quietDebounceScheduler = quietDebounceScheduler
        self.maxAgeScheduler = maxAgeScheduler
        self.retryBackoffScheduler = retryBackoffScheduler
        self.clock = clock
        self.diagnosticsReporter = diagnosticsReporter
        self.deviceIdentifier = deviceIdentifier
        self.onQueueAcknowledged = onQueueAcknowledged
        self.onHostVisibleAuthenticationFailure = onHostVisibleAuthenticationFailure
        self.onAuthenticationRecovered = onAuthenticationRecovered
        currentBackoff = configuration.uploadRetryBackoff
    }

    func install(auth: AuthProvider, transport: UploadTransport) {
        authProvider = auth
        self.transport = transport
    }

    func start() {
        wantsRunning = true
        pathObserver.onPathChanged = { [weak self] isSatisfied in
            guard let self, self.wantsRunning, isSatisfied else { return }
            self.flushOpportunistically()
        }
        pathObserver.start()
        Task { @MainActor [weak self] in
            await self?.refreshMaxAgeSchedule()
        }
    }

    func stop() {
        wantsRunning = false
        flushGeneration &+= 1
        uploadPausedUntil = nil
        flushAgain = false
        quietDebounceScheduler.cancel()
        maxAgeScheduler.cancel()
        retryBackoffScheduler.cancel()
        pathObserver.stop()
        pathObserver.onPathChanged = nil
    }

    /// Suspends until any in-flight `flushIfPossible` finishes (including after `stop()`).
    func waitForFlushToFinish() async {
        guard isFlushing else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            flushIdleWaiters.append(continuation)
        }
    }

    func setForeground(_ isForeground: Bool) {
        self.isForeground = isForeground
        if !isForeground {
            quietDebounceScheduler.cancel()
        }
    }

    func noteSightingActivity() {
        guard wantsRunning else { return }
        if isForeground {
            scheduleQuietDebounce()
        }
        Task { @MainActor [weak self] in
            await self?.refreshMaxAgeSchedule()
            await self?.flushAfterWakeIfNeeded()
        }
    }

    func noteQueueChanged() async {
        guard wantsRunning else { return }
        await refreshMaxAgeSchedule()
        await flushAfterWakeIfNeeded()
    }

    /// Immediate flush for lifecycle, connectivity return, max-age, and cold-start.
    func flushOpportunistically() {
        guard wantsRunning else { return }
        if isFlushing {
            flushAgain = true
            return
        }
        quietDebounceScheduler.cancel()
        Task { @MainActor [weak self] in
            await self?.flushIfPossible(maxBatches: nil)
        }
    }

    /// Connectivity-gated flush after enqueue / background ranging activity.
    ///
    /// Background wakes attempt a single batch only so the wake window stays
    /// short; the durable queue retains anything not uploaded. Foreground keeps
    /// a full drain (same as other opportunistic triggers).
    func flushAfterWakeIfNeeded() async {
        guard wantsRunning else { return }
        guard pathObserver.isSatisfied else { return }
        guard uploadPausedUntil == nil || clock.now >= (uploadPausedUntil ?? .distantPast) else {
            return
        }
        guard let queue = queueProvider() else { return }
        do {
            guard try await queue.oldestQueuedAt() != nil else { return }
        } catch {
            diagnosticsReporter.record(.durableQueueUnreadable, error: error)
            return
        }
        if isForeground {
            flushOpportunistically()
        } else {
            flushBounded(maxBatches: 1)
        }
    }

    /// At most `maxBatches` POSTs — used for background region-wake flushes.
    func flushBounded(maxBatches: Int = 1) {
        guard wantsRunning else { return }
        if isFlushing {
            flushAgain = true
            return
        }
        quietDebounceScheduler.cancel()
        let limit = max(1, maxBatches)
        Task { @MainActor [weak self] in
            await self?.flushIfPossible(maxBatches: limit)
        }
    }

    private func scheduleQuietDebounce() {
        guard uploadPausedUntil == nil || clock.now >= (uploadPausedUntil ?? .distantPast) else {
            return
        }
        quietDebounceScheduler.schedule(after: configuration.sendDebounce) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.flushIfPossible(maxBatches: nil)
            }
        }
    }

    private func refreshMaxAgeSchedule() async {
        guard wantsRunning, let queue = queueProvider() else {
            maxAgeScheduler.cancel()
            return
        }
        if let uploadPausedUntil, clock.now < uploadPausedUntil {
            maxAgeScheduler.cancel()
            return
        }
        do {
            guard let oldest = try await queue.oldestQueuedAt() else {
                maxAgeScheduler.cancel()
                return
            }
            let due = oldest.addingTimeInterval(configuration.maxQueueAge)
            let delay = due.timeIntervalSince(clock.now)
            maxAgeScheduler.schedule(after: Swift.max(0, delay)) { [weak self] in
                self?.flushOpportunistically()
            }
        } catch {
            diagnosticsReporter.record(.durableQueueUnreadable, error: error)
        }
    }

    /// - Parameter maxBatches: `nil` drains until empty/offline/failure; otherwise
    ///   stops after that many successful or attempted batch uploads.
    private func flushIfPossible(maxBatches: Int?) async {
        guard wantsRunning else { return }
        if isFlushing {
            flushAgain = true
            return
        }
        if let uploadPausedUntil, clock.now < uploadPausedUntil {
            let remaining = uploadPausedUntil.timeIntervalSince(clock.now)
            scheduleRetry(after: remaining, advanceExponentialBackoff: false)
            return
        }
        uploadPausedUntil = nil
        guard pathObserver.isSatisfied else { return }
        guard let queue = queueProvider() else { return }

        let generation = flushGeneration
        isFlushing = true
        defer {
            isFlushing = false
            let waiters = flushIdleWaiters
            flushIdleWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
            if flushAgain, wantsRunning {
                flushAgain = false
                Task { @MainActor [weak self] in
                    // A deferred re-flush from a concurrent trigger uses full drain.
                    await self?.flushIfPossible(maxBatches: nil)
                }
            } else {
                flushAgain = false
            }
        }

        var batchesAttempted = 0
        do {
            while wantsRunning, flushGeneration == generation, pathObserver.isSatisfied {
                if let maxBatches, batchesAttempted >= maxBatches {
                    return
                }
                if let uploadPausedUntil, clock.now < uploadPausedUntil {
                    return
                }

                let batch = try await queue.nextBatch(limit: configuration.uploadBatchLimit)
                guard wantsRunning, flushGeneration == generation else { return }
                guard !batch.isEmpty else {
                    currentBackoff = configuration.uploadRetryBackoff
                    maxAgeScheduler.cancel()
                    return
                }

                batchesAttempted += 1

                // Transport owns encode; preflight only so FakeTransport tests
                // still skip network when IDFV is missing (same diagnostic).
                guard let deviceId = deviceIdentifier.deviceId, !deviceId.isEmpty else {
                    diagnosticsReporter.record(
                        .deviceIdentifierUnavailable,
                        error: BeaconUploadPayloadEncoder.MissingDeviceIdentifier()
                    )
                    _ = await handleRetryableFailure(
                        queue: queue,
                        batch: batch,
                        consumesUploadAttempt: true
                    )
                    return
                }

                do {
                    let response = try await performUpload(batch: batch)
                    guard wantsRunning, flushGeneration == generation else { return }
                    switch response {
                    case .accepted(let ids):
                        let batchIDs = Set(batch.map(\.id))
                        let removable = ids.filter { batchIDs.contains($0) }
                        guard !removable.isEmpty else {
                            throw NoOpUploadAcknowledgement()
                        }
                        try await queue.acknowledge(ids: removable)
                        currentBackoff = configuration.uploadRetryBackoff
                        await onQueueAcknowledged?()
                        await refreshMaxAgeSchedule()
                    }
                } catch {
                    guard wantsRunning, flushGeneration == generation else { return }
                    let shouldStop = await handleUploadError(error, queue: queue, batch: batch)
                    if shouldStop {
                        return
                    }
                }
            }
        } catch {
            diagnosticsReporter.record(.uploadFailed, error: error)
            scheduleRetryBackoff()
        }
    }

    /// Obtains authorization and uploads. On 401/403, invalidates the cached
    /// token, refreshes once, and retries the same batch immediately.
    /// Host-visible auth notify is owned by `handleUploadError` (single path).
    private func performUpload(batch: [QueuedDetection]) async throws -> UploadResponse {
        let authorization = try await authProvider.validAuthorization()
        onAuthenticationRecovered?()
        do {
            return try await transport.upload(detections: batch, authorization: authorization)
        } catch {
            guard case .unauthorizedRefresh = UploadFailurePolicy.policy(for: error) else {
                throw error
            }
            authProvider.invalidateCachedToken()
            let refreshed = try await authProvider.validAuthorization()
            onAuthenticationRecovered?()
            return try await transport.upload(detections: batch, authorization: refreshed)
        }
    }

    private func notifyHostVisibleAuthenticationFailureIfNeeded(_ error: Error) {
        guard let authError = error as? TokenBrokerAuthError,
              authError.isHostVisibleAuthenticationFailure else {
            return
        }
        onHostVisibleAuthenticationFailure?()
    }

    /// Coarse, non-sensitive triage for host diagnostics (no tokens/bodies).
    private func uploadDiagnosticError(for error: Error) -> Error {
        if error is TokenBrokerAuthError {
            return DiagnosticNotice("tokenBroker")
        }
        if error is HTTPIngestUploadError {
            return DiagnosticNotice("ingest")
        }
        return error
    }

    /// Returns `true` when the flush loop should stop (retry scheduled / paused).
    private func handleUploadError(
        _ error: Error,
        queue: any DurableDetectionQueue,
        batch: [QueuedDetection]
    ) async -> Bool {
        guard wantsRunning else { return true }
        diagnosticsReporter.record(.uploadFailed, error: uploadDiagnosticError(for: error))
        notifyHostVisibleAuthenticationFailureIfNeeded(error)
        switch UploadFailurePolicy.policy(for: error) {
        case .deadLetterImmediately:
            await deadLetter(batch: batch, queue: queue)
            return false
        case .unauthorizedRefresh:
            return await handleRetryableFailure(
                queue: queue,
                batch: batch,
                consumesUploadAttempt: true
            )
        case .retryable(let backoff, let consumesUploadAttempt):
            return await handleRetryableFailure(
                queue: queue,
                batch: batch,
                backoff: backoff,
                consumesUploadAttempt: consumesUploadAttempt
            )
        }
    }

    /// Returns `true` when the flush loop should stop.
    private func handleRetryableFailure(
        queue: any DurableDetectionQueue,
        batch: [QueuedDetection],
        backoff: UploadFailurePolicy.RetryBackoffKind = .exponential,
        consumesUploadAttempt: Bool
    ) async -> Bool {
        guard wantsRunning else { return true }
        if consumesUploadAttempt {
            do {
                try await queue.recordUploadAttempts(for: batch.map(\.id))
                let refreshed = try await queue.nextBatch(limit: batch.count)
                let maxAttempts = configuration.maxUploadAttempts
                if refreshed.contains(where: { $0.uploadAttemptCount >= maxAttempts }) {
                    await deadLetter(batch: refreshed, queue: queue)
                    return false
                }
            } catch {
                diagnosticsReporter.record(.durableQueueWriteFailed, error: error)
            }
        }

        guard wantsRunning else { return true }
        switch backoff {
        case .exponential:
            scheduleRetryBackoff()
        case .rateLimited(let retryAfter):
            if let retryAfter {
                scheduleRetry(after: retryAfter, advanceExponentialBackoff: false)
            } else {
                scheduleRetryBackoff()
            }
        }
        return true
    }

    private func deadLetter(batch: [QueuedDetection], queue: any DurableDetectionQueue) async {
        guard wantsRunning else { return }
        do {
            let result = try await queue.deadLetter(ids: batch.map(\.id), now: clock.now)
            diagnosticsReporter.record(.uploadDeadLettered)
            if result.evictedCount > 0 {
                diagnosticsReporter.record(
                    .durableQueueEvicted,
                    error: DiagnosticNotice("dead-letter evicted \(result.evictedCount)")
                )
            }
            await onQueueAcknowledged?()
            await refreshMaxAgeSchedule()
        } catch {
            diagnosticsReporter.record(.durableQueueWriteFailed, error: error)
            scheduleRetryBackoff()
        }
    }

    private func scheduleRetryBackoff() {
        scheduleRetry(after: currentBackoff, advanceExponentialBackoff: true)
    }

    private func scheduleRetry(after delay: TimeInterval, advanceExponentialBackoff: Bool) {
        let wait = Swift.max(0, delay)
        uploadPausedUntil = clock.now.addingTimeInterval(wait)
        quietDebounceScheduler.cancel()
        maxAgeScheduler.cancel()
        retryBackoffScheduler.schedule(after: wait) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.uploadPausedUntil = nil
                await self.flushIfPossible(maxBatches: nil)
            }
        }
        if advanceExponentialBackoff {
            currentBackoff = min(
                currentBackoff * 2,
                configuration.uploadRetryBackoffMax
            )
        }
    }
}
