import Foundation
import CoreLocation

/// Maintains a low-power last-known `LocationFix` for observation-window stamping.
///
/// Coarse standard updates run only while detecting. Significant-change monitoring
/// keeps a background-capable baseline under Always authorization when enabled.
@MainActor
final class CoreLocationProvider: NSObject, LocationProviding {
    private(set) var currentLocation: LocationFix?

    private let configuration: SDKConfiguration
    private let locationManager: any DeviceLocationManaging
    private var wantsRunning = false
    private var isDetecting = false
    private var isSignificantChangeActive = false
    private var isCoarseUpdating = false

    init(
        configuration: SDKConfiguration = .default,
        locationManager: any DeviceLocationManaging = CLLocationManager()
    ) {
        self.configuration = configuration
        self.locationManager = locationManager
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = configuration.locationAccuracy
        locationManager.distanceFilter = configuration.locationDistanceFilterMeters
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.allowsBackgroundLocationUpdates = false
    }

    func start() {
        wantsRunning = true
        applyAuthorizationPolicy()
    }

    func stop() {
        wantsRunning = false
        isDetecting = false
        stopCoarseUpdates()
        stopSignificantChange()
        locationManager.allowsBackgroundLocationUpdates = false
    }

    func setDetecting(_ isDetecting: Bool) {
        self.isDetecting = isDetecting
        guard wantsRunning else { return }
        applyAuthorizationPolicy()
    }

    private func applyAuthorizationPolicy() {
        guard wantsRunning else {
            stopCoarseUpdates()
            stopSignificantChange()
            return
        }

        switch mappedAuthorization {
        case .always:
            locationManager.allowsBackgroundLocationUpdates = true
            if configuration.useSignificantChangeBaseline {
                startSignificantChange()
            } else {
                stopSignificantChange()
            }
            if isDetecting {
                startCoarseUpdates()
            } else {
                stopCoarseUpdates()
            }
        case .whenInUse:
            // Background location baseline requires Always. When-In-Use only
            // refreshes the cache with coarse updates while actively detecting.
            locationManager.allowsBackgroundLocationUpdates = false
            stopSignificantChange()
            if isDetecting {
                startCoarseUpdates()
            } else {
                stopCoarseUpdates()
            }
        case .notDetermined, .unavailable:
            locationManager.allowsBackgroundLocationUpdates = false
            stopCoarseUpdates()
            stopSignificantChange()
            currentLocation = nil
        }
    }

    private var mappedAuthorization: LocationAuthorization {
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

    private func startCoarseUpdates() {
        guard !isCoarseUpdating else { return }
        locationManager.desiredAccuracy = configuration.locationAccuracy
        locationManager.distanceFilter = configuration.locationDistanceFilterMeters
        locationManager.startUpdatingLocation()
        isCoarseUpdating = true
    }

    private func stopCoarseUpdates() {
        guard isCoarseUpdating else { return }
        locationManager.stopUpdatingLocation()
        isCoarseUpdating = false
    }

    private func startSignificantChange() {
        guard !isSignificantChangeActive else { return }
        locationManager.startMonitoringSignificantLocationChanges()
        isSignificantChangeActive = true
    }

    private func stopSignificantChange() {
        guard isSignificantChangeActive else { return }
        locationManager.stopMonitoringSignificantLocationChanges()
        isSignificantChangeActive = false
    }

    private func ingest(_ locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // Negative horizontalAccuracy means Core Location considers the fix invalid.
        guard location.horizontalAccuracy >= 0 else { return }
        currentLocation = LocationFix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )
    }
}

extension CoreLocationProvider: @MainActor CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        applyAuthorizationPolicy()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        ingest(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Retain the last good cached fix across transient failures.
        _ = error
    }
}
