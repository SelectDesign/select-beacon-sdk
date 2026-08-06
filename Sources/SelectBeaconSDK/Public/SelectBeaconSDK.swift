import Foundation

/// Main host-facing facade. All mutable facade state is main-actor isolated;
/// durable queue I/O runs on an actor so it does not block this executor.
@MainActor
public final class SelectBeaconSDK {

    /// The SDK instance the host app configures and controls.
    public static let shared = SelectBeaconSDK()

    /// The current non-sensitive operating state of the SDK.
    public private(set) var operationalStatus: SDKOperationalStatus = .unconfigured

    /// Receives non-sensitive changes to the SDK's operating state.
    public var onOperationalStatusChanged: ((SDKOperationalStatus) -> Void)?

    // MARK: - Select AppSupport SPI bridge

    /// Compile-time partition used only by `SelectBeaconAppSupport`. Applications
    /// must not import `@_spi(SelectApp)` directly.
    @_spi(SelectApp)
    public var onSelectActiveBeaconsChanged: (([BeaconObservation]) -> Void)?

    @_spi(SelectApp)
    public var onSelectPendingReportsChanged: (([SelectPendingBeaconReport]) -> Void)?

    @_spi(SelectApp)
    public var onSelectDeadLetteredReportsChanged: (([SelectPendingBeaconReport]) -> Void)?

    @_spi(SelectApp)
    public var onSelectOpenWindowsChanged: (([SelectOpenBeaconWindow]) -> Void)?

    /// True while a `stop()`-initiated finalize enqueue is still in flight.
    ///
    /// Empty open windows are published synchronously in `stop()` and must not
    /// be treated as proof that durable enqueue finished. Gate host Start on
    /// this flag (or `onSelectStopFinalizePendingChanged`) instead.
    @_spi(SelectApp)
    public private(set) var selectIsStopFinalizePending = false

    @_spi(SelectApp)
    public var onSelectStopFinalizePendingChanged: ((Bool) -> Void)?

    // MARK: - Dependencies and session state

    private let dependencies: SDKDependencies
    private var windowStore: ObservationWindowStore
    private var activeBeaconStore = ActiveBeaconStore()
    private let presenceExpiryScheduler: DelayedActionScheduling
    private let absenceExpiryScheduler: DelayedActionScheduling

    /// Created lazily so configure/init never starts ranging, observers, or disk I/O.
    private var engine: DetectionEngine?
    private var permissionObserver: PermissionObserver?
    private var lifecycleObserver: ApplicationLifecycleObserving?
    private var locationProvider: LocationProviding?
    private var uploadCoordinator: UploadCoordinator?
    private var installedAuthProvider: AuthProvider?
    private var installedUploadTransport: UploadTransport?
    private var queue: (any DurableDetectionQueue)?
    private var enablementConfiguration: SDKEnablementConfiguration?
    private var hasStarted = false
    private var session = RangingSessionState()

    /// Invalidates adapter notifications from an earlier start/stop generation.
    /// Already-finalized reports still persist; only callbacks are gated.
    private var deliverySession = 0

    /// Serial async chain so durable queue order matches Core Location delivery order.
    private var deliveryTask: Task<Void, Never>?

    /// Active stop-finalize generation. Distinct from ordinary window-close enqueues.
    private var activeStopFinalizeGeneration: Int?

    private init() {
        dependencies = .live
        windowStore = ObservationWindowStore(configuration: SDKConfiguration.default)
        presenceExpiryScheduler = TaskDelayedActionScheduler()
        absenceExpiryScheduler = TaskDelayedActionScheduler()
    }

    // MARK: - Public lifecycle

    /// Enables the SDK for this distributor or customer. Calling this does not begin detection.
    ///
    /// Production is the default. Staging callers must provide their own endpoint so multiple
    /// staging deployments can coexist. This validates and stores configuration
    /// only; it does not request permission, start Core Location, touch disk, or
    /// make a network request.
    public static func configure(
        appKey: String,
        appSecret: String,
        environment: Environment = .production
    ) {
        guard !shared.hasStarted else {
            shared.updateOperationalStatus(.degraded(.configurationLocked))
            return
        }
        guard let identity = AppIdentity(appKey: appKey, appSecret: appSecret) else {
            shared.invalidateConfiguration()
            shared.updateOperationalStatus(.degraded(.invalidConfiguration))
            return
        }
        shared.configure(identity: identity, environment: environment)
    }

    /// Starts detection only when `configure(appKey:appSecret:)` has completed.
    ///
    /// Records host intent to range. Actual ranging still depends on host-owned
    /// location authorization and, for When-In-Use, foreground activity.
    ///
    /// `deliverySession` is intentionally not bumped here. `stop()` already
    /// invalidates in-flight notifications and schedules stop-finalize under the
    /// new session; bumping again on `start()` would drop those reports.
    public func start() {
        guard enablementConfiguration != nil else {
            updateOperationalStatus(.degraded(.startRequestedBeforeConfiguration))
            return
        }
        hasStarted = true
        prepareObserversIfNeeded()
        prepareLocationProviderIfNeeded()
        prepareUploadCoordinatorIfNeeded()
        locationProvider?.start()
        uploadCoordinator?.start()
        apply(session.startRequested())
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.materializeDurableQueueIfNeeded()
            guard outcome.loaded else { return }
            await self.uploadCoordinator?.noteQueueChanged()
            if outcome.hadBacklog {
                self.uploadCoordinator?.flushOpportunistically()
            }
        }
    }

    /// Ensures `queue` references the durable store and disk contents are loaded.
    private struct MaterializeOutcome {
        var loaded: Bool
        var hadBacklog: Bool
    }

    @discardableResult
    private func materializeDurableQueueIfNeeded() async -> MaterializeOutcome {
        guard let queue = resolvedQueue() else {
            return MaterializeOutcome(loaded: false, hadBacklog: false)
        }
        do {
            let hadBacklog = try await queue.oldestQueuedAt() != nil
            return MaterializeOutcome(loaded: true, hadBacklog: hadBacklog)
        } catch {
            recordQueueFailure(error)
            return MaterializeOutcome(loaded: false, hadBacklog: false)
        }
    }

    /// Stops ranging and ends the active detection session.
    ///
    /// Open observation windows are finalized and enqueued. In-flight delivery
    /// work is not cancelled so already-finalized reports finish persisting;
    /// `deliverySession` only gates stale adapter notifications.
    public func stop() {
        deliverySession &+= 1
        apply(session.stopRequested())
        let finalized = windowStore.finalizeAllOpenWindows()
        absenceExpiryScheduler.cancel()
        if !finalized.isEmpty {
            // Arm pending before scheduling so hosts never observe empty open
            // windows without also seeing finalize-in-flight.
            let generation = deliverySession
            activeStopFinalizeGeneration = generation
            setStopFinalizePending(true)
            enqueueFinalizedReports(finalized, stopFinalizeGeneration: generation)
        } else if activeStopFinalizeGeneration == nil {
            // Do not clear an in-flight prior generation: a prior finalize task
            // may still be writing, and Start must stay gated until it settles.
            setStopFinalizePending(false)
        }
        notifyOpenWindowsChanged()
        clearActiveBeacons()
        locationProvider?.setDetecting(false)
        locationProvider?.stop()
        uploadCoordinator?.stop()
    }

    /// Installs auth and upload seams (package / test use).
    func selectInstallUploadSeams(auth: AuthProvider, transport: UploadTransport) {
        installedAuthProvider = auth
        installedUploadTransport = transport
        uploadCoordinator?.install(auth: auth, transport: transport)
    }

    /// BeaconTest / Select debug builds: acknowledge every flushed batch without a real API.
    @_spi(SelectApp)
    public func selectInstallDebugAutoAckUploadSeams() {
        selectInstallUploadSeams(
            auth: DebugAutoAckAuthProvider(),
            transport: DebugAutoAckUploadTransport()
        )
    }

    // MARK: - Configuration

    func configure(identity: AppIdentity, environment: Environment) {
        guard !hasStarted else {
            updateOperationalStatus(.degraded(.configurationLocked))
            return
        }
        guard let configuration = SDKEnablementConfiguration(
            identity: identity,
            environment: environment
        ) else {
            invalidateConfiguration()
            updateOperationalStatus(.degraded(.invalidConfiguration))
            return
        }
        // Pre-start reconfiguration can change customer or endpoint; the queue
        // namespace derives from both, so drop any already-materialized queue.
        queue = nil
        enablementConfiguration = configuration
        session.configure()
        updateOperationalStatus(.ready)
    }

    private func invalidateConfiguration() {
        enablementConfiguration = nil
        queue = nil
    }

    // MARK: - Observer and coordinator setup

    private func prepareObserversIfNeeded() {
        if permissionObserver == nil {
            let observer = dependencies.permissionObserverFactory()
            observer.onAuthorizationChanged = { [weak self] authorization in
                self?.apply(self?.session.authorizationChanged(authorization) ?? .none)
            }
            permissionObserver = observer
            apply(session.authorizationChanged(observer.authorization))
        }

        if lifecycleObserver == nil {
            let observer = dependencies.lifecycleObserverFactory()
            observer.onActivityChanged = { [weak self] isActive in
                guard let self else { return }
                self.apply(self.session.applicationActivityChanged(isActive))
                // Always + background keeps the engine started (monitoring on);
                // sync ranging policy. WhenInUse + inactive already stopped the engine.
                if self.session.isRanging {
                    self.engine?.setApplicationActive(isActive)
                }
                self.uploadCoordinator?.setForeground(isActive)
                self.uploadCoordinator?.flushOpportunistically()
            }
            lifecycleObserver = observer
            apply(session.applicationActivityChanged(observer.isActive))
            uploadCoordinator?.setForeground(observer.isActive)
        }
    }

    private func prepareLocationProviderIfNeeded() {
        if locationProvider == nil {
            locationProvider = dependencies.locationProviderFactory()
        }
    }

    private func prepareUploadCoordinatorIfNeeded() {
        if uploadCoordinator == nil {
            let deviceIdentifier = dependencies.deviceIdentifierFactory()
            let auth = installedAuthProvider
                ?? makeLiveAuthProvider()
                ?? dependencies.authProviderFactory()
            let transport = installedUploadTransport
                ?? makeLiveUploadTransport(deviceIdentifier: deviceIdentifier)
                ?? dependencies.uploadTransportFactory()
            uploadCoordinator = UploadCoordinator(
                configuration: SDKConfiguration.default,
                queueProvider: { [weak self] in self?.queue },
                authProvider: auth,
                transport: transport,
                pathObserver: dependencies.networkPathObserverFactory(),
                quietDebounceScheduler: dependencies.quietDebounceSchedulerFactory(),
                maxAgeScheduler: dependencies.maxAgeSchedulerFactory(),
                retryBackoffScheduler: dependencies.retryBackoffSchedulerFactory(),
                clock: dependencies.clock,
                diagnosticsReporter: dependencies.diagnosticsReporter,
                deviceIdentifier: deviceIdentifier,
                onQueueAcknowledged: { [weak self] in
                    await self?.publishPendingReportsSnapshot()
                    await self?.publishDeadLetteredReportsSnapshot()
                }
            )
            if let lifecycleObserver {
                uploadCoordinator?.setForeground(lifecycleObserver.isActive)
            }
        }
    }

    private func makeLiveAuthProvider() -> AuthProvider? {
        guard enablementConfiguration?.endpoint.isUsableHTTPBase == true else {
            return nil
        }
        guard let configuration = enablementConfiguration?.tokenBrokerConfiguration() else {
            return nil
        }
        return TokenBrokerAuthProvider(
            configuration: configuration,
            clock: dependencies.clock
        )
    }

    private func makeLiveUploadTransport(
        deviceIdentifier: DeviceIdentifying
    ) -> UploadTransport? {
        guard let ingestURL = enablementConfiguration?.endpoint.ingestURL else {
            return nil
        }
        return HTTPIngestUploadTransport(
            ingestURL: ingestURL,
            deviceIdentifier: deviceIdentifier,
            clock: dependencies.clock
        )
    }

    // MARK: - Ranging

    private func apply(_ effect: RangingSessionState.Effect) {
        switch effect {
        case .none:
            break
        case .startRanging:
            let engine = detectionEngine()
            engine.start(uuids: SDKConfiguration.default.monitoredUUIDs)
            engine.setApplicationActive(session.isApplicationActive)
            session.didStartRanging()
            locationProvider?.setDetecting(true)
        case .stopRanging:
            engine?.stop()
            session.didStopRanging()
            locationProvider?.setDetecting(false)
            clearActiveBeacons()
        }
        updateOperationalStatusForSession()
    }

    private func detectionEngine() -> DetectionEngine {
        if let engine {
            return engine
        }

        let engine = dependencies.engineFactory()
        engine.onBeacons = { [weak self] beacons in
            self?.handle(beacons)
        }
        self.engine = engine
        return engine
    }

    private func handle(_ beacons: [DetectedBeacon]) {
        guard enablementConfiguration != nil, session.isRanging else { return }
        let now = dependencies.clock.now
        let cachedLocation = locationProvider?.currentLocation
        var finalizedReports: [FinalizedBeaconReport] = []
        var acceptedSighting = false

        for beacon in beacons {
            // Engine already drops unknown RSSI (0); keep a defensive guard here.
            guard beacon.rssi < 0 else { continue }
            acceptedSighting = true
            let observation = BeaconObservation(
                uuid: beacon.uuid,
                major: beacon.major,
                minor: beacon.minor,
                rssi: beacon.rssi,
                observedAt: now
            )
            activeBeaconStore.record(observation)
            notifyActiveBeaconsChanged()
            schedulePresenceExpiry()

            let effect = windowStore.process(
                beacon: beacon,
                location: cachedLocation,
                now: now
            )
            switch effect {
            case .updated:
                break
            case .closed(let report, _):
                finalizedReports.append(report)
            }
        }

        if acceptedSighting {
            uploadCoordinator?.noteSightingActivity()
            notifyOpenWindowsChanged()
        }
        scheduleAbsenceExpiry()
        if !finalizedReports.isEmpty {
            enqueueFinalizedReports(finalizedReports)
        }
    }

    // MARK: - Durable report persistence

    private func enqueueFinalizedReports(
        _ reports: [FinalizedBeaconReport],
        stopFinalizeGeneration: Int? = nil
    ) {
        let session = deliverySession
        let precedingTask = deliveryTask
        let queuedAt = dependencies.clock.now
        let detections = reports.map { QueuedDetection(report: $0, queuedAt: queuedAt) }
        deliveryTask = Task { @MainActor [weak self] in
            await precedingTask?.value
            await self?.deliver(detections, for: session)
            if let stopFinalizeGeneration {
                await self?.completeStopFinalizeIfCurrent(
                    stopFinalizeGeneration,
                    deliverySession: session
                )
            }
            // Flush after durable write (+ stop-finalize settlement) so upload
            // work cannot delay clearing `selectIsStopFinalizePending`.
            await self?.uploadCoordinator?.noteQueueChanged()
        }
    }

    private func completeStopFinalizeIfCurrent(
        _ generation: Int,
        deliverySession: Int
    ) async {
        guard activeStopFinalizeGeneration == generation else { return }
        activeStopFinalizeGeneration = nil
        setStopFinalizePending(false)
        // Current-session enqueues already published their snapshots. A later
        // stop suppresses those stale callbacks, so publish once on settlement.
        if deliverySession != self.deliverySession {
            await publishPendingReportsSnapshot()
        }
    }

    private func setStopFinalizePending(_ pending: Bool) {
        guard selectIsStopFinalizePending != pending else { return }
        selectIsStopFinalizePending = pending
        onSelectStopFinalizePendingChanged?(pending)
    }

    private func deliver(_ detections: [QueuedDetection], for session: Int) async {
        for detection in detections {
            await enqueue(detection, for: session)
        }
    }

    private func enqueue(_ detection: QueuedDetection, for session: Int) async {
        do {
            guard let queue = resolvedQueue() else { return }
            // Persist even when deliverySession advanced: finalized reports must
            // not be abandoned. Adapter notifications stay session-gated below.
            let result = try await queue.enqueue(detection, now: dependencies.clock.now)
            if result.evictedCount > 0 {
                dependencies.diagnosticsReporter.record(
                    .durableQueueEvicted,
                    error: DiagnosticNotice("evicted \(result.evictedCount)")
                )
            }
            if shouldNotify(for: session) {
                await publishPendingReportsSnapshot(deliverySession: session)
            }
        } catch {
            recordQueueFailure(error)
        }
    }

    // MARK: - AppSupport snapshots

    @_spi(SelectApp)
    public var selectActiveBeaconObservations: [BeaconObservation] {
        activeBeaconStore.snapshot
    }

    @_spi(SelectApp)
    public var selectOpenWindowSnapshots: [SelectOpenBeaconWindow] {
        windowStore.snapshot.map(SelectOpenBeaconWindow.init)
    }

    @_spi(SelectApp)
    public func selectPendingReports() async throws -> [SelectPendingBeaconReport] {
        guard let queue = resolvedQueue() else { return [] }
        let records = try await queue.pendingRecords()
        return records.map(\.pendingReport)
    }

    @_spi(SelectApp)
    public func selectDeadLetteredReports() async throws -> [SelectPendingBeaconReport] {
        guard let queue = resolvedQueue() else { return [] }
        let records = try await queue.deadLetteredRecords()
        return records.map(\.pendingReport)
    }

    /// Empties the durable pending queue and publishes an empty AppSupport snapshot.
    ///
    /// Refuses while detection intent is on or a stop-finalize enqueue is still
    /// settling, so clear cannot race an in-flight durable write from stop.
    @_spi(SelectApp)
    public func selectClearPendingReports() async throws {
        guard enablementConfiguration != nil else {
            throw SelectPendingReportsClearError.notConfigured
        }
        guard !session.wantsRanging else {
            throw SelectPendingReportsClearError.detectionActive
        }
        guard !selectIsStopFinalizePending else {
            throw SelectPendingReportsClearError.stopFinalizePending
        }

        guard let queue = resolvedQueue() else {
            throw SelectPendingReportsClearError.notConfigured
        }
        try await queue.clear()

        // Publish after clear so snapshot reads see recovered storage, then
        // clear durable-queue degrade if the queue is healthy again.
        await publishPendingReportsSnapshot()
        await publishDeadLetteredReportsSnapshot()

        if case .degraded(.durableQueueUnreadable) = operationalStatus {
            updateOperationalStatusForSession()
        }
    }

    private func notifyActiveBeaconsChanged() {
        onSelectActiveBeaconsChanged?(activeBeaconStore.snapshot)
    }

    private func notifyOpenWindowsChanged() {
        onSelectOpenWindowsChanged?(selectOpenWindowSnapshots)
    }

    private func clearActiveBeacons() {
        presenceExpiryScheduler.cancel()
        guard activeBeaconStore.clear() else { return }
        notifyActiveBeaconsChanged()
    }

    private func schedulePresenceExpiry() {
        guard let oldestObservation = activeBeaconStore.nextExpiry else {
            presenceExpiryScheduler.cancel()
            return
        }
        let expiry = oldestObservation.addingTimeInterval(SDKConfiguration.default.absenceTimeout)
        let delay = expiry.timeIntervalSince(dependencies.clock.now)
        presenceExpiryScheduler.schedule(after: delay) { [weak self] in
            self?.expireActiveBeacons()
        }
    }

    private func expireActiveBeacons() {
        guard session.isRanging else { return }
        let cutoff = dependencies.clock.now.addingTimeInterval(
            -SDKConfiguration.default.absenceTimeout
        )
        if activeBeaconStore.expire(before: cutoff) {
            notifyActiveBeaconsChanged()
        }
        schedulePresenceExpiry()
    }

    private func scheduleAbsenceExpiry() {
        guard let deadline = windowStore.nextAbsenceDeadline else {
            absenceExpiryScheduler.cancel()
            return
        }
        let delay = deadline.timeIntervalSince(dependencies.clock.now)
        absenceExpiryScheduler.schedule(after: delay) { [weak self] in
            self?.expireObservationWindows()
        }
    }

    private func expireObservationWindows() {
        let now = dependencies.clock.now
        let closed = windowStore.expireAbsences(now: now)
        if !closed.isEmpty {
            enqueueFinalizedReports(closed)
        }
        notifyOpenWindowsChanged()
        scheduleAbsenceExpiry()
    }

    /// Publishes the pending-queue snapshot after enqueue, upload acknowledgement,
    /// or stop-finalize settlement. When `deliverySession` is set, skips the
    /// callback if that session is no longer current (stale ranging delivery).
    private func publishPendingReportsSnapshot(deliverySession: Int? = nil) async {
        do {
            let reports = try await selectPendingReports()
            if let deliverySession, !shouldNotify(for: deliverySession) {
                return
            }
            onSelectPendingReportsChanged?(reports)
        } catch {
            recordQueueFailure(error, forceUnreadable: true)
        }
    }

    /// Publishes the dead-letter snapshot after upload acknowledgement or
    /// dead-letter. Quietly degrades on unreadable store, same as pending.
    private func publishDeadLetteredReportsSnapshot() async {
        do {
            let reports = try await selectDeadLetteredReports()
            onSelectDeadLetteredReportsChanged?(reports)
        } catch {
            recordQueueFailure(error, forceUnreadable: true)
        }
    }

    /// Materializes the durable queue for the current enablement configuration.
    private func resolvedQueue() -> (any DurableDetectionQueue)? {
        guard let configuration = enablementConfiguration else { return nil }
        if queue == nil {
            queue = dependencies.queueFactory(configuration.queueStorageIdentifier)
        }
        return queue
    }

    /// Records a durable-queue I/O failure and degrades operational status.
    ///
    /// When `forceUnreadable` is true (pending snapshot reads), always maps to
    /// `.durableQueueUnreadable` to match historical adapter-facing behavior.
    private func recordQueueFailure(_ error: Error, forceUnreadable: Bool = false) {
        let event: DiagnosticEvent
        if forceUnreadable {
            event = .durableQueueUnreadable
        } else if case DurableDetectionQueueError.unreadableStoredDetections = error {
            event = .durableQueueUnreadable
        } else {
            event = .durableQueueWriteFailed
        }
        dependencies.diagnosticsReporter.record(event, error: error)
        updateOperationalStatus(
            .degraded(
                event == .durableQueueUnreadable
                    ? .durableQueueUnreadable
                    : .durableQueueWriteFailed
            )
        )
    }

    // MARK: - Operational status

    private func updateOperationalStatusForSession() {
        guard enablementConfiguration != nil else {
            updateOperationalStatus(.unconfigured)
            return
        }
        guard session.wantsRanging else {
            updateOperationalStatus(.ready)
            return
        }
        switch session.authorization {
        case .notDetermined:
            updateOperationalStatus(.awaitingPermission)
        case .unavailable:
            updateOperationalStatus(.degraded(.locationPermissionUnavailable))
        case .whenInUse where !session.isApplicationActive:
            updateOperationalStatus(.paused)
        case .always, .whenInUse:
            updateOperationalStatus(session.isRanging ? .ranging : .paused)
        }
    }

    private func updateOperationalStatus(_ status: SDKOperationalStatus) {
        guard operationalStatus != status else { return }
        operationalStatus = status
        onOperationalStatusChanged?(status)
    }

    private func shouldNotify(for session: Int) -> Bool {
        // Protects callbacks after an async boundary from an earlier start/stop
        // generation. Do not require `isRanging`: a temporary pause can stop
        // ranging while an already-started durable write finishes.
        session == deliverySession
    }

    // MARK: - Test seams

    init(
        engine: @escaping () -> DetectionEngine,
        permissionObserver: @escaping () -> PermissionObserver,
        lifecycleObserver: @escaping () -> ApplicationLifecycleObserving,
        clock: Clock,
        queue: @escaping (String) -> any DurableDetectionQueue,
        locationProvider: @escaping () -> LocationProviding = { CoreLocationProvider() },
        authProvider: @escaping () -> AuthProvider = { DeferredAuthProvider() },
        uploadTransport: @escaping () -> UploadTransport = { DeferredUploadTransport() },
        networkPathObserver: @escaping () -> NetworkPathObserving = { NetworkPathObserver() },
        quietDebounceScheduler: @escaping () -> DelayedActionScheduling = { TaskDelayedActionScheduler() },
        maxAgeScheduler: @escaping () -> DelayedActionScheduling = { TaskDelayedActionScheduler() },
        retryBackoffScheduler: @escaping () -> DelayedActionScheduling = { TaskDelayedActionScheduler() },
        deviceIdentifier: @escaping () -> DeviceIdentifying = { VendorDeviceIdentifier() },
        diagnosticsReporter: DiagnosticsReporting = NoopDiagnosticsReporter(),
        presenceExpiryScheduler: DelayedActionScheduling = TaskDelayedActionScheduler(),
        absenceExpiryScheduler: DelayedActionScheduling = TaskDelayedActionScheduler(),
        identity: AppIdentity?,
        environment: Environment = .production
    ) {
        dependencies = SDKDependencies(
            engineFactory: engine,
            permissionObserverFactory: permissionObserver,
            lifecycleObserverFactory: lifecycleObserver,
            queueFactory: queue,
            locationProviderFactory: locationProvider,
            authProviderFactory: authProvider,
            uploadTransportFactory: uploadTransport,
            networkPathObserverFactory: networkPathObserver,
            quietDebounceSchedulerFactory: quietDebounceScheduler,
            maxAgeSchedulerFactory: maxAgeScheduler,
            retryBackoffSchedulerFactory: retryBackoffScheduler,
            deviceIdentifierFactory: deviceIdentifier,
            clock: clock,
            diagnosticsReporter: diagnosticsReporter
        )
        windowStore = ObservationWindowStore(configuration: SDKConfiguration.default)
        self.presenceExpiryScheduler = presenceExpiryScheduler
        self.absenceExpiryScheduler = absenceExpiryScheduler
        if let identity,
           let configuration = SDKEnablementConfiguration(
                identity: identity,
                environment: environment
           ) {
            enablementConfiguration = configuration
        }
        if enablementConfiguration != nil {
            session.configure()
            operationalStatus = .ready
        }
    }

    var configuredEnvironment: Environment? {
        enablementConfiguration?.environment
    }

    var configuredEndpoint: APIEndpoint? {
        enablementConfiguration?.endpoint
    }
}
