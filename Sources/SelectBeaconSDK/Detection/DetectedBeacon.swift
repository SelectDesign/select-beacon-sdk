import Foundation

/// Platform-neutral iBeacon observation from the detection engine.
struct DetectedBeacon: Equatable, Sendable {
    let uuid: UUID
    let major: Int
    let minor: Int
    let rssi: Int
}
