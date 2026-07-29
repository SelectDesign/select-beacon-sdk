import Foundation

/// Seam for Core Location ranging and test fakes.
@MainActor
protocol DetectionEngine: AnyObject {
    var onBeacons: (([DetectedBeacon]) -> Void)? { get set }
    func start(uuids: [UUID])
    func stop()
}
