import CoreLocation

/// Maps host-owned Core Location authorization into SDK policy states.
///
/// The SDK never requests permission. Live observation is owned by
/// `CoreLocationDetectionEngine` (shared beacon `CLLocationManager`).
enum LocationAuthorization: Equatable {
    case notDetermined
    case whenInUse
    case always
    case unavailable

    init(status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            self = .always
        case .authorizedWhenInUse:
            self = .whenInUse
        case .notDetermined:
            self = .notDetermined
        case .denied, .restricted:
            self = .unavailable
        @unknown default:
            self = .unavailable
        }
    }
}

@MainActor
protocol PermissionObserver: AnyObject {
    var authorization: LocationAuthorization { get }
    var onAuthorizationChanged: ((LocationAuthorization) -> Void)? { get set }
}
