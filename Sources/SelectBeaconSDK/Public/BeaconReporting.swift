import Foundation

/// A valid beacon sighting received from Core Location.
@_spi(SelectApp)
public struct BeaconObservation: Equatable, Sendable {
    public let uuid: UUID
    public let major: Int
    public let minor: Int
    public let rssi: Int
    public let observedAt: Date

    public init(
        uuid: UUID,
        major: Int,
        minor: Int,
        rssi: Int,
        observedAt: Date
    ) {
        self.uuid = uuid
        self.major = major
        self.minor = minor
        self.rssi = rssi
        self.observedAt = observedAt
    }
}

/// How a specific observation was handled by the SDK's windowing logic.
@_spi(SelectApp)
public enum BeaconObservationDisposition: Equatable, Sendable {
    /// The sighting updated an open observation window without finalizing a report.
    case windowUpdated

    /// The sighting caused a window to close and produced a durable report record.
    case reportCreated(reportID: UUID)

    /// Durable storage failed while finalizing a report.
    case reportFailed(reportID: UUID)
}

/// The upload lifecycle of a durable report record.
@_spi(SelectApp)
public enum BeaconReportStatus: Equatable, Sendable {
    /// The record is durably stored and eligible for upload.
    case queued

    /// Reserved for a future upload coordinator.
    case uploading

    /// Reserved for a future API acknowledgement.
    case acknowledged

    /// Durable storage or a future upload attempt failed.
    case failed
}

/// A durable report record and its lifecycle status.
@_spi(SelectApp)
public struct BeaconReport: Equatable, Sendable {
    public let id: UUID
    public let status: BeaconReportStatus

    public init(id: UUID, status: BeaconReportStatus) {
        self.id = id
        self.status = status
    }
}

/// A lifecycle change for a durable report record.
@_spi(SelectApp)
public struct BeaconReportStatusUpdate: Equatable, Sendable {
    public let report: BeaconReport

    public init(report: BeaconReport) {
        self.report = report
    }
}

/// Correlates a beacon observation with its disposition and any created report.
@_spi(SelectApp)
public struct BeaconActivityUpdate: Equatable, Sendable {
    public let observation: BeaconObservation
    public let disposition: BeaconObservationDisposition
    public let report: BeaconReport?

    public init(
        observation: BeaconObservation,
        disposition: BeaconObservationDisposition,
        report: BeaconReport?
    ) {
        self.observation = observation
        self.disposition = disposition
        self.report = report
    }
}

/// A durable report record exposed only to the Select application adapter.
@_spi(SelectApp)
public struct SelectPendingBeaconReport: Equatable, Sendable {
    public let id: UUID
    public let uuid: UUID
    public let major: Int
    public let minor: Int
    public let bestRSSI: Int
    public let latestTimestamp: Date
    public let windowStartedAt: Date
    public let observationCount: Int
    public let location: LocationFix?
    public let queuedAt: Date

    public init(
        id: UUID,
        uuid: UUID,
        major: Int,
        minor: Int,
        bestRSSI: Int,
        latestTimestamp: Date,
        windowStartedAt: Date,
        observationCount: Int,
        location: LocationFix?,
        queuedAt: Date
    ) {
        self.id = id
        self.uuid = uuid
        self.major = major
        self.minor = minor
        self.bestRSSI = bestRSSI
        self.latestTimestamp = latestTimestamp
        self.windowStartedAt = windowStartedAt
        self.observationCount = observationCount
        self.location = location
        self.queuedAt = queuedAt
    }
}

/// An open observation window's running aggregates for Select-app UI.
@_spi(SelectApp)
public struct SelectOpenBeaconWindow: Equatable, Sendable {
    public let uuid: UUID
    public let major: Int
    public let minor: Int
    public let bestRSSI: Int
    public let latestTimestamp: Date
    public let windowStartedAt: Date
    public let observationCount: Int
    public let location: LocationFix?

    public init(
        uuid: UUID,
        major: Int,
        minor: Int,
        bestRSSI: Int,
        latestTimestamp: Date,
        windowStartedAt: Date,
        observationCount: Int,
        location: LocationFix?
    ) {
        self.uuid = uuid
        self.major = major
        self.minor = minor
        self.bestRSSI = bestRSSI
        self.latestTimestamp = latestTimestamp
        self.windowStartedAt = windowStartedAt
        self.observationCount = observationCount
        self.location = location
    }

    init(_ summary: OpenWindowSummary) {
        uuid = summary.uuid
        major = summary.major
        minor = summary.minor
        bestRSSI = summary.bestRSSI
        latestTimestamp = summary.latestTimestamp
        windowStartedAt = summary.windowStartedAt
        observationCount = summary.observationCount
        location = summary.location
    }
}
