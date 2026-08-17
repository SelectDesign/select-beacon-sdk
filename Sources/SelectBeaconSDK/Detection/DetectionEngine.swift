import Foundation

/// Seam for Core Location region monitoring / ranging and test fakes.
@MainActor
protocol DetectionEngine: AnyObject {
    var onBeacons: (([DetectedBeacon]) -> Void)? { get set }
    func start(uuids: [UUID])
    func stop()
    /// Syncs foreground vs background ranging policy while monitoring stays on.
    func setApplicationActive(_ isActive: Bool)
}

extension DetectionEngine {
    func setApplicationActive(_ isActive: Bool) {}
}
