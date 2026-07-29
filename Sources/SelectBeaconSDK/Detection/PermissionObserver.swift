import CoreLocation

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
        LocationAuthorization(status: locationManager.authorizationStatus)
    }
}

extension CoreLocationPermissionObserver: @MainActor CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChanged?(authorization)
    }
}
