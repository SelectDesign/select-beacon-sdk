import CoreLocation

/// Minimal wrapper around the Apple API, allowing tests to substitute a fake
/// location manager instead of requiring a physical iBeacon-capable device.
@MainActor
protocol LocationManaging: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    func startRangingBeacons(satisfying constraint: CLBeaconIdentityConstraint)
    func stopRangingBeacons(satisfying constraint: CLBeaconIdentityConstraint)
    func startMonitoring(for region: CLRegion)
    func stopMonitoring(for region: CLRegion)
    func requestState(for region: CLRegion)
}

extension CLLocationManager: @MainActor LocationManaging {}

// MARK: - The real engine, backed by Core Location

/// Translates Apple `CLBeacon` objects into the SDK's platform-neutral model.
///
/// Region monitoring is the wake layer (can resume a suspended app under Always
/// authorization when the host enables background location). Ranging via
/// `CLBeaconIdentityConstraint` captures major/minor/RSSI. The same
/// `CLLocationManager` / delegate also observes host authorization — no separate
/// permission-only manager and no CoreBluetooth.
///
/// Real background wakes also require the host app's location background mode
/// (`UIBackgroundModes` / capability). That is a VIP/BizStride configuration
/// item; this type only implements the Core Location mechanism.
///
/// This class intentionally owns no reporting or persistence policy.
@MainActor
final class CoreLocationDetectionEngine: NSObject, DetectionEngine, PermissionObserver {

    /// Soft cap on beacon regions this SDK starts. iOS allows 20 monitored
    /// regions per app; the budget is shared with the host (Footmarks, etc.).
    static let maxMonitoredBeaconUUIDs = 5

    var onBeacons: (([DetectedBeacon]) -> Void)?
    var onAuthorizationChanged: ((LocationAuthorization) -> Void)?

    private let locationManager: any LocationManaging
    private var monitoredRegionsByUUID: [UUID: CLBeaconRegion] = [:]
    private var constraintsByUUID: [UUID: CLBeaconIdentityConstraint] = [:]
    private var activelyRangingUUIDs: Set<UUID> = []
    private var isApplicationActive = true
    private var isStarted = false

    init(locationManager: any LocationManaging = CLLocationManager()) {
        self.locationManager = locationManager
        super.init()
        locationManager.delegate = self
    }

    var authorization: LocationAuthorization {
        LocationAuthorization(status: locationManager.authorizationStatus)
    }

    func start(uuids: [UUID]) {
        // Rebuild monitoring and ranging on each start so a stop/start session
        // cannot leave a stale region or constraint active in Core Location.
        stop()

        // Cap to keep headroom in the shared 20-region app budget.
        let limited = Array(uuids.prefix(Self.maxMonitoredBeaconUUIDs))
        isStarted = true

        for uuid in limited {
            let constraint = CLBeaconIdentityConstraint(uuid: uuid)
            constraintsByUUID[uuid] = constraint

            let region = CLBeaconRegion(uuid: uuid, identifier: uuid.uuidString)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            region.notifyEntryStateOnDisplay = true
            monitoredRegionsByUUID[uuid] = region
            locationManager.startMonitoring(for: region)
            locationManager.requestState(for: region)
        }

        // Foreground: continuous ranging for responsiveness. Background: wait
        // for enter / determined-state inside before ranging.
        if isApplicationActive {
            startRangingAllMonitoredConstraints()
        }
    }

    func stop() {
        for uuid in activelyRangingUUIDs {
            if let constraint = constraintsByUUID[uuid] {
                locationManager.stopRangingBeacons(satisfying: constraint)
            }
        }
        activelyRangingUUIDs.removeAll()

        for region in monitoredRegionsByUUID.values {
            locationManager.stopMonitoring(for: region)
        }
        monitoredRegionsByUUID.removeAll()
        constraintsByUUID.removeAll()
        isStarted = false
    }

    func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive
        guard isStarted else { return }
        if isActive {
            startRangingAllMonitoredConstraints()
        } else {
            // Keep region monitoring; drop continuous ranging while suspended /
            // backgrounded. Enter/inside callbacks restart short ranging bursts.
            stopRangingAllActiveConstraints()
        }
    }

    private func startRangingAllMonitoredConstraints() {
        for uuid in constraintsByUUID.keys {
            startRanging(for: uuid)
        }
    }

    private func stopRangingAllActiveConstraints() {
        let active = activelyRangingUUIDs
        for uuid in active {
            stopRanging(for: uuid)
        }
    }

    private func startRanging(for uuid: UUID) {
        guard let constraint = constraintsByUUID[uuid] else { return }
        guard !activelyRangingUUIDs.contains(uuid) else { return }
        locationManager.startRangingBeacons(satisfying: constraint)
        activelyRangingUUIDs.insert(uuid)
    }

    private func stopRanging(for uuid: UUID) {
        guard let constraint = constraintsByUUID[uuid] else { return }
        guard activelyRangingUUIDs.contains(uuid) else { return }
        locationManager.stopRangingBeacons(satisfying: constraint)
        activelyRangingUUIDs.remove(uuid)
    }

    private func uuid(for region: CLRegion) -> UUID? {
        if let beaconRegion = region as? CLBeaconRegion {
            return beaconRegion.uuid
        }
        return UUID(uuidString: region.identifier)
    }
}

extension CoreLocationDetectionEngine: @MainActor CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChanged?(authorization)
    }

    func locationManager(
        _ manager: CLLocationManager,
        didRange beacons: [CLBeacon],
        satisfying beaconConstraint: CLBeaconIdentityConstraint
    ) {
        let mapped = beacons.compactMap { beacon -> DetectedBeacon? in
            // Core Location uses 0 for unknown RSSI. It is not a very weak
            // signal, so it must not enter observation-window aggregates.
            guard beacon.rssi < 0 else { return nil }
            return DetectedBeacon(
                uuid: beacon.uuid,
                major: beacon.major.intValue,
                minor: beacon.minor.intValue,
                rssi: beacon.rssi
            )
        }
        guard !mapped.isEmpty else { return }
        onBeacons?(mapped)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let uuid = uuid(for: region) else { return }
        startRanging(for: uuid)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let uuid = uuid(for: region) else { return }
        stopRanging(for: uuid)
    }

    func locationManager(
        _ manager: CLLocationManager,
        didDetermineState state: CLRegionState,
        for region: CLRegion
    ) {
        guard let uuid = uuid(for: region) else { return }
        switch state {
        case .inside:
            startRanging(for: uuid)
        case .outside, .unknown:
            stopRanging(for: uuid)
        @unknown default:
            stopRanging(for: uuid)
        }
    }
}
