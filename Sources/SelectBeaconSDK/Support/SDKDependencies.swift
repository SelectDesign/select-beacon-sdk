import Foundation

/// Injectable factories for the live SDK graph (engine, queue, upload, clocks).
///
/// Tests construct this via `SelectBeaconSDK`'s test initializer. Live
/// `permissionObserverFactory` is `nil` so auth observation uses the detection
/// engine's shared `CLLocationManager` (two-manager design).
@MainActor
struct SDKDependencies {
    let engineFactory: () -> DetectionEngine
    /// When nil, the facade uses the detection engine as `PermissionObserver`.
    let permissionObserverFactory: (() -> PermissionObserver)?
    let lifecycleObserverFactory: () -> ApplicationLifecycleObserving
    let queueFactory: (String) -> any DurableDetectionQueue
    let locationProviderFactory: () -> LocationProviding
    let authProviderFactory: () -> AuthProvider
    let uploadTransportFactory: () -> UploadTransport
    let networkPathObserverFactory: () -> NetworkPathObserving
    let quietDebounceSchedulerFactory: () -> DelayedActionScheduling
    let maxAgeSchedulerFactory: () -> DelayedActionScheduling
    let retryBackoffSchedulerFactory: () -> DelayedActionScheduling
    let deviceIdentifierFactory: () -> DeviceIdentifying
    let clock: Clock
    let diagnosticsReporter: DiagnosticsReporting

    static func makeLive(diagnosticsReporter: DiagnosticsReporting) -> SDKDependencies {
        SDKDependencies(
            engineFactory: { CoreLocationDetectionEngine() },
            permissionObserverFactory: nil,
            lifecycleObserverFactory: { ApplicationLifecycleObserver() },
            queueFactory: { FileDetectionQueue(storageIdentifier: $0) },
            locationProviderFactory: { CoreLocationProvider() },
            authProviderFactory: { DeferredAuthProvider() },
            uploadTransportFactory: { DeferredUploadTransport() },
            networkPathObserverFactory: { NetworkPathObserver() },
            quietDebounceSchedulerFactory: { TaskDelayedActionScheduler() },
            maxAgeSchedulerFactory: { TaskDelayedActionScheduler() },
            retryBackoffSchedulerFactory: { TaskDelayedActionScheduler() },
            deviceIdentifierFactory: { VendorDeviceIdentifier() },
            clock: SystemClock(),
            diagnosticsReporter: diagnosticsReporter
        )
    }
}
