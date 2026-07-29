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
