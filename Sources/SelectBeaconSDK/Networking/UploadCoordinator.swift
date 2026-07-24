import Foundation
import Network

/// Observes whether the device currently has a usable network path.
@MainActor
protocol NetworkPathObserving: AnyObject {
    var isSatisfied: Bool { get }
    var onPathChanged: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
final class NetworkPathObserver: NetworkPathObserving {
    var onPathChanged: ((Bool) -> Void)?
    private(set) var isSatisfied = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "SelectBeaconSDK.NetworkPathObserver")
    private var hasStarted = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                guard self.isSatisfied != satisfied else { return }
                self.isSatisfied = satisfied
                self.onPathChanged?(satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        monitor.cancel()
    }
}

/// Schedules a single delayed action; rescheduling cancels the previous one.
@MainActor
protocol SendDebounceScheduling: AnyObject {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class TaskSendDebounceScheduler: SendDebounceScheduling {
    private var task: Task<Void, Never>?

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Swift.max(0, delay)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.task = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Transmits durable queued reports using quiet debounce, max-age, and opportunistic triggers.
///
/// Enqueue readiness is owned by observation windows. This type only decides
/// when to attempt network delivery.
@MainActor
final class UploadCoordinator {
    private let configuration: SDKConfiguration
    private let queueProvider: () -> (any DurableDetectionQueue)?
    private var authProvider: AuthProvider
    private var transport: UploadTransport
    private let pathObserver: NetworkPathObserving
    private let quietDebounceScheduler: SendDebounceScheduling
    private let maxAgeScheduler: SendDebounceScheduling
    private let retryBackoffScheduler: SendDebounceScheduling
    private let clock: Clock
    private let diagnosticsReporter: DiagnosticsReporting
    private let deviceIdentifier: DeviceIdentifying
    private let payloadEncoder: BeaconUploadPayloadEncoder
    private let onQueueAcknowledged: (@MainActor () async -> Void)?

    private var wantsRunning = false
    private var isForeground = true
    private var isFlushing = false
    private var currentBackoff: TimeInterval

    /// Returned when the transport accepts a batch but acknowledges no queued IDs.
    struct NoOpUploadAcknowledgement: Error {}

    init(
        configuration: SDKConfiguration = .default,
        queueProvider: @escaping () -> (any DurableDetectionQueue)?,
        authProvider: AuthProvider,
        transport: UploadTransport,
        pathObserver: NetworkPathObserving,
        quietDebounceScheduler: SendDebounceScheduling = TaskSendDebounceScheduler(),
        maxAgeScheduler: SendDebounceScheduling = TaskSendDebounceScheduler(),
        retryBackoffScheduler: SendDebounceScheduling = TaskSendDebounceScheduler(),
        clock: Clock,
        diagnosticsReporter: DiagnosticsReporting = NoopDiagnosticsReporter(),
        deviceIdentifier: DeviceIdentifying = VendorDeviceIdentifier(),
        payloadEncoder: BeaconUploadPayloadEncoder = BeaconUploadPayloadEncoder(),
        onQueueAcknowledged: (@MainActor () async -> Void)? = nil
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
        self.payloadEncoder = payloadEncoder
        self.onQueueAcknowledged = onQueueAcknowledged
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
            // Connectivity return is an immediate opportunistic trigger.
            self.flushOpportunistically()
        }
        pathObserver.start()
    }

    func stop() {
        wantsRunning = false
        quietDebounceScheduler.cancel()
        maxAgeScheduler.cancel()
        retryBackoffScheduler.cancel()
        pathObserver.stop()
        pathObserver.onPathChanged = nil
    }

    /// Tracks application activity for foreground-only quiet debounce.
    func setForeground(_ isForeground: Bool) {
        self.isForeground = isForeground
        if !isForeground {
            quietDebounceScheduler.cancel()
        }
    }

    /// Resets the foreground quiet-debounce timer after any valid beacon sighting.
    func noteSightingActivity() {
        guard wantsRunning else { return }
        if isForeground {
            scheduleQuietDebounce()
        }
        Task { @MainActor [weak self] in
            await self?.refreshMaxAgeSchedule()
        }
    }

    /// Refreshes the max-queue-age cap after durable enqueue / queue mutation.
    func noteQueueChanged() async {
        guard wantsRunning else { return }
        await refreshMaxAgeSchedule()
    }

    /// Immediate flush for lifecycle, connectivity return, and max-age fires.
    func flushOpportunistically() {
        guard wantsRunning else { return }
        quietDebounceScheduler.cancel()
        Task { @MainActor [weak self] in
            await self?.flushIfPossible()
        }
    }

    private func scheduleQuietDebounce() {
        quietDebounceScheduler.schedule(after: configuration.sendDebounce) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.flushIfPossible()
            }
        }
    }

    private func refreshMaxAgeSchedule() async {
        guard wantsRunning, let queue = queueProvider() else {
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

    private func flushIfPossible() async {
        guard wantsRunning, !isFlushing else { return }
        // Offline triggers do nothing now; connectivity-return will retry.
        guard pathObserver.isSatisfied else { return }
        guard let queue = queueProvider() else { return }

        isFlushing = true
        defer { isFlushing = false }

        do {
            while wantsRunning, pathObserver.isSatisfied {
                let batch = try await queue.nextBatch(limit: configuration.uploadBatchLimit)
                guard !batch.isEmpty else {
                    currentBackoff = configuration.uploadRetryBackoff
                    maxAgeScheduler.cancel()
                    return
                }

                // Prove the confirmed wire body can be built (including deviceId)
                // before asking auth/transport. Live HTTP still posts this later.
                do {
                    _ = try payloadEncoder.encode(batch, deviceId: deviceIdentifier.deviceId)
                } catch {
                    diagnosticsReporter.record(.deviceIdentifierUnavailable, error: error)
                    scheduleRetryBackoff()
                    return
                }

                // One short-lived token per batch, not per report.
                let token = try await authProvider.validToken()
                let response = try await transport.upload(detections: batch, bearerToken: token)
                if case .accepted(let ids) = response {
                    // `nextBatch` is a non-destructive peek. Empty or unknown IDs
                    // would leave the queue unchanged and spin this loop forever.
                    let batchIDs = Set(batch.map(\.id))
                    let removable = ids.filter { batchIDs.contains($0) }
                    guard !removable.isEmpty else {
                        throw NoOpUploadAcknowledgement()
                    }
                    try await queue.acknowledge(ids: removable)
                    currentBackoff = configuration.uploadRetryBackoff
                    await onQueueAcknowledged?()
                    await refreshMaxAgeSchedule()
                } else {
                    return
                }
            }
        } catch {
            diagnosticsReporter.record(.uploadFailed, error: error)
            scheduleRetryBackoff()
        }
    }

    private func scheduleRetryBackoff() {
        retryBackoffScheduler.schedule(after: currentBackoff) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.flushIfPossible()
            }
        }
        currentBackoff = min(
            currentBackoff * 2,
            configuration.uploadRetryBackoffMax
        )
    }
}
