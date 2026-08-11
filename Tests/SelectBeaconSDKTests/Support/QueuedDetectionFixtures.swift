import Foundation
@testable import SelectBeaconSDK

enum QueuedDetectionFixtures {
    static let fleetUUID = SDKConfiguration.default.monitoredUUIDs[0]

    static func make(
        uuid: UUID = fleetUUID,
        major: Int = 1,
        minor: Int = 42,
        bestRSSI: Int = -55,
        latestTimestamp: Date = Date(timeIntervalSince1970: 1_000_000),
        windowStartedAt: Date? = nil,
        observationCount: Int = 1,
        location: LocationFix? = nil,
        queuedAt: Date? = nil
    ) -> QueuedDetection {
        let latest = latestTimestamp
        return QueuedDetection(
            uuid: uuid,
            major: major,
            minor: minor,
            bestRSSI: bestRSSI,
            latestTimestamp: latest,
            windowStartedAt: windowStartedAt ?? latest,
            observationCount: observationCount,
            location: location,
            queuedAt: queuedAt ?? latest
        )
    }
}
