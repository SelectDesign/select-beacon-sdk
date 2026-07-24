import Foundation

/// SDK-owned device location snapshot. Never expose `CLLocation` through this type.
///
/// `timestamp` is when Core Location produced the fix, not when a beacon was seen.
/// Standard host apps do not receive location through `SelectBeaconSDK`'s lifecycle
/// API; Select pending reports may include it via `SelectBeaconAppSupport`.
public struct LocationFix: Equatable, Sendable, Codable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let timestamp: Date

    public init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }
}
