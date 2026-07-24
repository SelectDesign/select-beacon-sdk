import CoreLocation

enum LocationAuthorization: Equatable {
    case notDetermined
    case whenInUse
    case always
    case unavailable
}

@MainActor
protocol PermissionObserver: AnyObject {
    var authorization: LocationAuthorization { get }
    var onAuthorizationChanged: ((LocationAuthorization) -> Void)? { get set }
}

/// Observes host-owned Core Location authorization. It never asks for permission.
@MainActor
final class CoreLocationPermissionObserver: NSObject, PermissionObserver {
    var onAuthorizationChanged: ((LocationAuthorization) -> Void)?

    private let locationManager: CLLocationManager

    init(locationManager: CLLocationManager = CLLocationManager()) {
        self.locationManager = locationManager
        super.init()
        self.locationManager.delegate = self
    }

    var authorization: LocationAuthorization {
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            return .always
        case .authorizedWhenInUse:
            return .whenInUse
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

}

extension CoreLocationPermissionObserver: @MainActor CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChanged?(authorization)
    }
}
