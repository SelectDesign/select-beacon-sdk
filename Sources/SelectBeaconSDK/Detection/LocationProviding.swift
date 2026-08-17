import Foundation
import CoreLocation

/// Low-power cached device location for stamping beacon observation windows.
@MainActor
protocol LocationProviding: AnyObject {
    /// Most recent usable fix, or `nil` when unavailable / never received.
    var currentLocation: LocationFix? { get }

    /// Begins observing authorization and applying the configured update policy.
    /// Does not request authorization.
    func start()

    /// Stops significant-change and coarse updates.
    func stop()

    /// Enables or disables coarse standard updates. Significant-change baseline
    /// (when configured) remains independent of this flag under Always auth.
    func setDetecting(_ isDetecting: Bool)
}

/// Injectable Core Location surface for the device-location provider.
@MainActor
protocol DeviceLocationManaging: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }

    func startUpdatingLocation()
    func stopUpdatingLocation()
    func startMonitoringSignificantLocationChanges()
    func stopMonitoringSignificantLocationChanges()
}

extension CLLocationManager: @MainActor DeviceLocationManaging {}
