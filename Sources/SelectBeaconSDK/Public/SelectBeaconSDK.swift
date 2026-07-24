import Foundation

/// `@MainActor` is Swift's main-thread/serial-executor guarantee. It means all
/// mutable facade state below is read and changed in one ordered context, much
/// like routing UI state through a single process. Disk I/O remains async in
/// the queue actor, so it does not block this actor while it is waiting.
@MainActor
public final class SelectBeaconSDK {

    /// The SDK instance the host app configures and controls.
    public static let shared = SelectBeaconSDK()

    /// The current non-sensitive operating state of the SDK.
    public private(set) var operationalStatus: SDKOperationalStatus = .unconfigured

    /// Receives non-sensitive changes to the SDK's operating state.
    public var onOperationalStatusChanged: ((SDKOperationalStatus) -> Void)?

    /// This is intentionally hidden from ordinary SDK consumers. `@_spi` is a
    /// compile-time API partition used only by `SelectBeaconAppSupport`; it is
    /// not a security mechanism and applications must not import it directly.
    @_spi(SelectApp)
    public var onSelectActiveBeaconsChanged: (([BeaconObservation]) -> Void)?

    @_spi(SelectApp)
    public var onSelectPendingReportsChanged: (([SelectPendingBeaconReport]) -> Void)?

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

    @_spi(SelectApp)
    public var onBeaconObserved: ((BeaconObservation) -> Void)?

    @_spi(SelectApp)
    public var onBeaconActivityUpdated: ((BeaconActivityUpdate) -> Void)?

    @_spi(SelectApp)
    public var onBeaconReportStatusUpdated: ((BeaconReportStatusUpdate) -> Void)?

    @_spi(SelectApp)
    public var onDetection: ((DetectedBeacon) -> Void)?

    /// Dependencies are factories/protocols rather than concrete Apple types so
    /// tests can replace Core Location, time, and file storage deterministically.
    private let dependencies: SDKDependencies

    /// Observation windows aggregate sightings into finalized reports.
    /// `ActiveBeaconStore` remains separate for in-range UI presence.
    private var windowStore: ObservationWindowStore
    private var activeBeaconStore = ActiveBeaconStore()
    private let presenceExpiryScheduler: PresenceExpiryScheduling
    private let absenceExpiryScheduler: PresenceExpiryScheduling

    /// These resources are created lazily. Creating the facade or configuring it
    /// therefore never begins ranging, observes lifecycle notifications, or opens
    /// the persisted queue.
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
    /// Incrementing this token invalidates work created by an earlier start/stop
    /// session. It is the Swift equivalent of rejecting a stale async job result.
    private var deliverySession = 0

    /// A serial async chain. A new ranging batch waits for its predecessor before
    /// writing to disk so durable queue order matches Core Location delivery order.
    private var deliveryTask: Task<Void, Never>?

    /// Active stop-finalize generation. Distinct from `deliveryTask`, which is
    /// also used by ordinary window-close enqueues while ranging.
    private var activeStopFinalizeGeneration: Int?

    private init() {
        dependencies = .live
        windowStore = ObservationWindowStore(configuration: SDKConfiguration.default)
        presenceExpiryScheduler = TaskPresenceExpiryScheduler()
        absenceExpiryScheduler = TaskPresenceExpiryScheduler()
    }

    /// Enables the SDK for this distributor or customer. Calling this does not begin detection.
    ///
    /// Production is the default. Staging callers must provide their own endpoint so multiple
    /// staging deployments can coexist. This validates and stores configuration
    /// only; it does not request permission, start Core Location, touch disk, or
    /// make a network request.
    public static func configure(
        appKey: String,
        environment: Environment = .production
    ) {
        guard !shared.hasStarted else {
            shared.updateOperationalStatus(.degraded(.configurationLocked))
            return
        }
        guard let identity = AppIdentity(appKey: appKey) else {
            shared.invalidateConfiguration()
            shared.updateOperationalStatus(.degraded(.invalidConfiguration))
            return
        }
        shared.configure(identity: identity, environment: environment)
    }

    /// Starts detection only when `configure(appKey:)` has completed.
    ///
    /// This records the host's intent to range. Actual ranging still depends on
    /// the host-owned location authorization and, for When-In-Use permission,
    /// whether the app is foreground active.
    ///
    /// `deliverySession` is intentionally not bumped here. `stop()` already
    /// invalidates in-flight ranging deliveries and schedules stop-finalize
    /// enqueues under the new session; bumping again on `start()` would drop
    /// those finalized open-window reports.
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
    }

    /// Stops ranging and ends the active detection session.
    ///
    /// Open observation windows are finalized and enqueued so an in-progress
    /// minute is not lost. Pending disk work is cancelled or made stale with
    /// `deliverySession`; already-committed queue records remain durable.
    public func stop() {
        deliverySession &+= 1
        deliveryTask?.cancel()
        deliveryTask = nil
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
            // No armed stop-finalize work. Do not clear an in-flight prior
            // generation here: a cancelled finalize task may still be inside
            // `queue.enqueue`, and Start must stay gated until it settles.
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
        // A pre-start reconfiguration can change the customer or endpoint.
        // The queue namespace derives from both, so an already materialized
        // queue must never carry over into the new configuration.
        queue = nil
        enablementConfiguration = configuration
        session.configure()
        updateOperationalStatus(.ready)
    }

    private func invalidateConfiguration() {
        // Do not leave a previous customer key or queue usable after a failed
        // replacement attempt. `start()` will now surface the configuration
        // failure instead of silently ranging under stale credentials.
        enablementConfiguration = nil
        queue = nil
    }

    private func prepareObserversIfNeeded() {
        // These observer closures are intentionally weak. Notification observers
        // may outlive a particular SDK instance in tests, so they must not retain
        // the facade through a reference cycle.
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
                // Lifecycle transitions flush opportunistically. Sparse
                // region-entry wakes never call flush from `handle(_:)`.
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
                }
            )
            if let lifecycleObserver {
                uploadCoordinator?.setForeground(lifecycleObserver.isActive)
            }
        }
    }

    private func makeLiveAuthProvider() -> AuthProvider? {
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
            deviceIdentifier: deviceIdentifier
        )
    }

    private func apply(_ effect: RangingSessionState.Effect) {
        // `RangingSessionState` owns policy; this method performs its requested
        // side effect. Keeping the decision and effect separate makes the policy
        // a pure, easily tested state machine.
        switch effect {
        case .none:
            break
        case .startRanging:
            let engine = detectionEngine()
            engine.start(uuids: SDKConfiguration.default.monitoredUUIDs)
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
            // Core Location reports 0 for unavailable RSSI; it cannot support aggregates.
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
            onBeaconObserved?(observation)

            let sighting = BeaconSighting(
                uuid: beacon.uuid,
                major: beacon.major,
                minor: beacon.minor,
                rssi: beacon.rssi
            )
            let effect = windowStore.process(
                sighting: sighting,
                location: cachedLocation,
                now: now
            )
            switch effect {
            case .updated:
                onBeaconActivityUpdated?(
                    BeaconActivityUpdate(
                        observation: observation,
                        disposition: .windowUpdated,
                        report: nil
                    )
                )
            case .closed(let report, _):
                finalizedReports.append(report)
            }
        }

        if acceptedSighting {
            // Quiet debounce is sighting-driven; never flush from a ranging wake.
            uploadCoordinator?.noteSightingActivity()
            notifyOpenWindowsChanged()
        }
        scheduleAbsenceExpiry()
        if !finalizedReports.isEmpty {
            enqueueFinalizedReports(finalizedReports)
        }
    }

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
            // Clear only when this task still owns the active stop generation so
            // a cancelled prior stop-finalize cannot hide newer pending work.
            if let stopFinalizeGeneration {
                self?.completeStopFinalizeIfCurrent(stopFinalizeGeneration)
            }
        }
    }

    private func completeStopFinalizeIfCurrent(_ generation: Int) {
        guard activeStopFinalizeGeneration == generation else { return }
        activeStopFinalizeGeneration = nil
        setStopFinalizePending(false)
    }

    private func setStopFinalizePending(_ pending: Bool) {
        guard selectIsStopFinalizePending != pending else { return }
        selectIsStopFinalizePending = pending
        onSelectStopFinalizePendingChanged?(pending)
    }

    private func deliver(_ detections: [QueuedDetection], for session: Int) async {
        for detection in detections {
            guard shouldDeliver(for: session) else { return }
            await enqueue(detection, for: session)
        }
    }

    private func enqueue(_ detection: QueuedDetection, for session: Int) async {
        do {
            guard shouldDeliver(for: session),
                  let configuration = enablementConfiguration else {
                return
            }
            let queue = self.queue ?? dependencies.queueFactory(configuration.queueStorageIdentifier)
            self.queue = queue
            // Crossing this `await` enters the queue actor. Swift allows other
            // main-actor work to run while file I/O is in progress, so validate
            // the session again after resuming.
            try await queue.enqueue(detection)
            guard shouldDeliver(for: session) else { return }
            let report = BeaconReport(id: detection.id, status: .queued)
            onBeaconReportStatusUpdated?(BeaconReportStatusUpdate(report: report))
            onBeaconActivityUpdated?(
                BeaconActivityUpdate(
                    observation: observation(for: detection),
                    disposition: .reportCreated(reportID: detection.id),
                    report: report
                )
            )
            onDetection?(detection.beacon)
            await notifyPendingReportsChanged(for: session)
            await uploadCoordinator?.noteQueueChanged()
        } catch {
            let event: DiagnosticEvent
            if case DurableDetectionQueueError.unreadableStoredDetections = error {
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
            guard shouldDeliver(for: session) else { return }
            let report = BeaconReport(id: detection.id, status: .failed)
            onBeaconReportStatusUpdated?(BeaconReportStatusUpdate(report: report))
            onBeaconActivityUpdated?(
                BeaconActivityUpdate(
                    observation: observation(for: detection),
                    disposition: .reportFailed(reportID: detection.id),
                    report: report
                )
            )
        }
    }

    private func observation(for detection: QueuedDetection) -> BeaconObservation {
        BeaconObservation(
            uuid: detection.uuid,
            major: detection.major,
            minor: detection.minor,
            rssi: detection.bestRSSI,
            observedAt: detection.latestTimestamp
        )
    }

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
        // This is a read-only FIFO snapshot. It may load a file created by a
        // previous app launch, so callers must handle the async/throwing boundary.
        guard let configuration = enablementConfiguration else { return [] }
        let queue = self.queue ?? dependencies.queueFactory(configuration.queueStorageIdentifier)
        self.queue = queue
        let records = try await queue.pendingRecords()
        return records.map(\.pendingReport)
    }

    /// Empties the durable pending queue and publishes an empty AppSupport snapshot.
    ///
    /// Refuses while detection intent is on or a stop-finalize enqueue is still
    /// settling, so clear cannot race an in-flight durable write from stop.
    @_spi(SelectApp)
    public func selectClearPendingReports() async throws {
        guard let configuration = enablementConfiguration else {
            throw SelectPendingReportsClearError.notConfigured
        }
        guard !session.wantsRanging else {
            throw SelectPendingReportsClearError.detectionActive
        }
        guard !selectIsStopFinalizePending else {
            throw SelectPendingReportsClearError.stopFinalizePending
        }

        let queue = self.queue ?? dependencies.queueFactory(configuration.queueStorageIdentifier)
        self.queue = queue
        try await queue.clear()

        // Clearing overwrites corrupted payloads, so recover unreadable
        // degradation when the session is otherwise healthy.
        if case .degraded(.durableQueueUnreadable) = operationalStatus {
            updateOperationalStatusForSession()
        }

        await publishPendingReportsSnapshot()
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

    private func notifyPendingReportsChanged(for session: Int) async {
        do {
            let reports = try await selectPendingReports()
            guard shouldDeliver(for: session) else { return }
            onSelectPendingReportsChanged?(reports)
        } catch {
            dependencies.diagnosticsReporter.record(.durableQueueUnreadable, error: error)
            updateOperationalStatus(.degraded(.durableQueueUnreadable))
        }
    }

    /// Publishes the pending-queue snapshot after upload acknowledgement.
    ///
    /// Unlike delivery-session notifications, this is not gated by ranging
    /// session tokens — a background flush may complete after `stop()`.
    private func publishPendingReportsSnapshot() async {
        do {
            let reports = try await selectPendingReports()
            onSelectPendingReportsChanged?(reports)
        } catch {
            dependencies.diagnosticsReporter.record(.durableQueueUnreadable, error: error)
            updateOperationalStatus(.degraded(.durableQueueUnreadable))
        }
    }

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

    private func shouldDeliver(for session: Int) -> Bool {
        // This protects every callback after an async boundary from an earlier
        // explicit start/stop session. Do not require `isRanging` here: a
        // temporary permission or foreground pause can stop ranging while an
        // already-started durable write finishes, and the adapter still needs
        // to learn that the report was queued.
        !Task.isCancelled && session == deliverySession
    }

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
        quietDebounceScheduler: @escaping () -> SendDebounceScheduling = { TaskSendDebounceScheduler() },
        maxAgeScheduler: @escaping () -> SendDebounceScheduling = { TaskSendDebounceScheduler() },
        retryBackoffScheduler: @escaping () -> SendDebounceScheduling = { TaskSendDebounceScheduler() },
        deviceIdentifier: @escaping () -> DeviceIdentifying = { VendorDeviceIdentifier() },
        diagnosticsReporter: DiagnosticsReporting = NoopDiagnosticsReporter(),
        presenceExpiryScheduler: PresenceExpiryScheduling = TaskPresenceExpiryScheduler(),
        absenceExpiryScheduler: PresenceExpiryScheduling = TaskPresenceExpiryScheduler(),
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

    var hasCreatedEngine: Bool {
        engine != nil
    }
}

// MARK: - The seam: a protocol the real engine and a fake engine both satisfy

@MainActor
protocol DetectionEngine: AnyObject {
    var onBeacons: (([DetectedBeacon]) -> Void)? { get set }
    func start(uuids: [UUID])
    func stop()
}
