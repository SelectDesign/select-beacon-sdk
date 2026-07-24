import Foundation

@MainActor
struct SDKDependencies {
    let engineFactory: () -> DetectionEngine
    let permissionObserverFactory: () -> PermissionObserver
    let lifecycleObserverFactory: () -> ApplicationLifecycleObserving
    let queueFactory: (String) -> any DurableDetectionQueue
    let locationProviderFactory: () -> LocationProviding
    let authProviderFactory: () -> AuthProvider
    let uploadTransportFactory: () -> UploadTransport
    let networkPathObserverFactory: () -> NetworkPathObserving
    let quietDebounceSchedulerFactory: () -> SendDebounceScheduling
    let maxAgeSchedulerFactory: () -> SendDebounceScheduling
    let retryBackoffSchedulerFactory: () -> SendDebounceScheduling
    let deviceIdentifierFactory: () -> DeviceIdentifying
    let clock: Clock
    let diagnosticsReporter: DiagnosticsReporting

    static let live = SDKDependencies(
        engineFactory: { CoreLocationDetectionEngine() },
        permissionObserverFactory: { CoreLocationPermissionObserver() },
        lifecycleObserverFactory: { ApplicationLifecycleObserver() },
        queueFactory: { FileDetectionQueue(storageIdentifier: $0) },
        locationProviderFactory: { CoreLocationProvider() },
        authProviderFactory: { DeferredAuthProvider() },
        uploadTransportFactory: { DeferredUploadTransport() },
        networkPathObserverFactory: { NetworkPathObserver() },
        quietDebounceSchedulerFactory: { TaskSendDebounceScheduler() },
        maxAgeSchedulerFactory: { TaskSendDebounceScheduler() },
        retryBackoffSchedulerFactory: { TaskSendDebounceScheduler() },
        deviceIdentifierFactory: { VendorDeviceIdentifier() },
        clock: SystemClock(),
        diagnosticsReporter: NoopDiagnosticsReporter()
    )
}
