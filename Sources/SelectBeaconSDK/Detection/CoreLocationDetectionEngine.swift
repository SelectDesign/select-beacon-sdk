import CoreLocation

/// Minimal wrapper around the Apple API, allowing tests to substitute a fake
/// location manager instead of requiring a physical iBeacon-capable device.
@MainActor
protocol LocationManaging: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    func startRangingBeacons(satisfying constraint: CLBeaconIdentityConstraint)
    func stopRangingBeacons(satisfying constraint: CLBeaconIdentityConstraint)
}

extension CLLocationManager: @MainActor LocationManaging {}

// MARK: - The real engine, backed by Core Location

/// Translates Apple `CLBeacon` objects into the SDK's platform-neutral model.
///
/// This class intentionally owns no reporting or persistence policy. It only
/// starts/stops the constraints requested by the facade and forwards valid
/// ranging observations on the main actor.
@MainActor
final class CoreLocationDetectionEngine: NSObject, DetectionEngine {

    var onBeacons: (([DetectedBeacon]) -> Void)?

    private let locationManager: any LocationManaging
    private var constraints: [CLBeaconIdentityConstraint] = []

    init(locationManager: any LocationManaging = CLLocationManager()) {
        self.locationManager = locationManager
        super.init()
        locationManager.delegate = self
    }

    func start(uuids: [UUID]) {
        // Rebuild constraints on each start so a stop/start session cannot leave
        // an old UUID ranging in Core Location.
        stop()
        constraints = uuids.map { CLBeaconIdentityConstraint(uuid: $0) }
        for constraint in constraints {
            locationManager.startRangingBeacons(satisfying: constraint)
        }
    }

    func stop() {
        for constraint in constraints {
            locationManager.stopRangingBeacons(satisfying: constraint)
        }
        constraints = []
    }

}

extension CoreLocationDetectionEngine: @MainActor CLLocationManagerDelegate {
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
}
