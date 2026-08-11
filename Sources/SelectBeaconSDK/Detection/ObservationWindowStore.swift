import Foundation

/// The stable identity of a physical iBeacon in Select's fleet.
struct BeaconIdentity: Hashable {
    let uuid: UUID
    let major: Int
    let minor: Int

    init(uuid: UUID, major: Int, minor: Int) {
        self.uuid = uuid
        self.major = major
        self.minor = minor
    }

    init(_ beacon: DetectedBeacon) {
        self.init(uuid: beacon.uuid, major: beacon.major, minor: beacon.minor)
    }
}

/// Finalized observation-window aggregates ready for durable enqueue.
struct FinalizedBeaconReport: Equatable, Sendable {
    let uuid: UUID
    let major: Int
    let minor: Int
    let bestRSSI: Int
    let latestTimestamp: Date
    let windowStartedAt: Date
    let observationCount: Int
    let location: LocationFix?
}

/// Read-only view of an open observation window for Select-app UI.
struct OpenWindowSummary: Equatable, Sendable {
    let uuid: UUID
    let major: Int
    let minor: Int
    let bestRSSI: Int
    let latestTimestamp: Date
    let windowStartedAt: Date
    let observationCount: Int
    let location: LocationFix?
}

enum ObservationWindowEffect: Equatable {
    case updated
    case closed(FinalizedBeaconReport, openedReplacement: Bool)
}

/// Pure, in-memory observation windows that aggregate sightings into reports.
///
/// Pass `now` into every method. The store never reads the system clock.
struct ObservationWindowStore {
    let windowDuration: TimeInterval
    let absenceTimeout: TimeInterval

    private struct OpenWindow {
        let identity: BeaconIdentity
        let windowStartedAt: Date
        var bestRSSI: Int
        var latestTimestamp: Date
        var observationCount: Int
        var location: LocationFix?
    }

    private var windows: [BeaconIdentity: OpenWindow] = [:]

    init(configuration: SDKConfiguration) {
        self.init(
            windowDuration: configuration.windowDuration,
            absenceTimeout: configuration.absenceTimeout
        )
    }

    init(windowDuration: TimeInterval, absenceTimeout: TimeInterval) {
        self.windowDuration = windowDuration
        self.absenceTimeout = absenceTimeout
    }

    /// Stable-ordered snapshot of every open window's running aggregates.
    var snapshot: [OpenWindowSummary] {
        windows.values
            .sorted(by: Self.windowSort)
            .map { window in
                OpenWindowSummary(
                    uuid: window.identity.uuid,
                    major: window.identity.major,
                    minor: window.identity.minor,
                    bestRSSI: window.bestRSSI,
                    latestTimestamp: window.latestTimestamp,
                    windowStartedAt: window.windowStartedAt,
                    observationCount: window.observationCount,
                    location: window.location
                )
            }
    }

    /// The soonest absence deadline among open windows, if any.
    var nextAbsenceDeadline: Date? {
        windows.values
            .map { $0.latestTimestamp.addingTimeInterval(absenceTimeout) }
            .min()
    }

    /// Finalizes every open window without opening replacements (used on SDK stop).
    mutating func finalizeAllOpenWindows() -> [FinalizedBeaconReport] {
        let reports = windows.values
            .sorted(by: Self.windowSort)
            .map(finalize)
        windows.removeAll()
        return reports
    }

    mutating func process(
        beacon: DetectedBeacon,
        location: LocationFix?,
        now: Date
    ) -> ObservationWindowEffect {
        let identity = BeaconIdentity(beacon)

        guard var existing = windows[identity] else {
            windows[identity] = OpenWindow(
                identity: identity,
                windowStartedAt: now,
                bestRSSI: beacon.rssi,
                latestTimestamp: now,
                observationCount: 1,
                location: location
            )
            return .updated
        }

        let elapsed = now.timeIntervalSince(existing.windowStartedAt)
        if elapsed > windowDuration {
            let closed = finalize(existing)
            windows[identity] = OpenWindow(
                identity: identity,
                windowStartedAt: now,
                bestRSSI: beacon.rssi,
                latestTimestamp: now,
                observationCount: 1,
                location: location
            )
            return .closed(closed, openedReplacement: true)
        }

        existing.bestRSSI = max(existing.bestRSSI, beacon.rssi)
        existing.latestTimestamp = now
        existing.observationCount += 1
        if let location {
            existing.location = location
        }
        windows[identity] = existing
        return .updated
    }

    /// Closes windows whose latest sighting is older than `absenceTimeout`.
    mutating func expireAbsences(now: Date) -> [FinalizedBeaconReport] {
        let expired = windows.values
            .filter { now.timeIntervalSince($0.latestTimestamp) > absenceTimeout }
            .sorted(by: Self.windowSort)
        var closed: [FinalizedBeaconReport] = []
        for window in expired {
            closed.append(finalize(window))
            windows[window.identity] = nil
        }
        return closed
    }

    private func finalize(_ window: OpenWindow) -> FinalizedBeaconReport {
        FinalizedBeaconReport(
            uuid: window.identity.uuid,
            major: window.identity.major,
            minor: window.identity.minor,
            bestRSSI: window.bestRSSI,
            latestTimestamp: window.latestTimestamp,
            windowStartedAt: window.windowStartedAt,
            observationCount: window.observationCount,
            location: window.location
        )
    }

    private static func windowSort(_ lhs: OpenWindow, _ rhs: OpenWindow) -> Bool {
        if lhs.windowStartedAt != rhs.windowStartedAt {
            return lhs.windowStartedAt < rhs.windowStartedAt
        }
        if lhs.identity.major != rhs.identity.major {
            return lhs.identity.major < rhs.identity.major
        }
        if lhs.identity.minor != rhs.identity.minor {
            return lhs.identity.minor < rhs.identity.minor
        }
        return lhs.identity.uuid.uuidString < rhs.identity.uuid.uuidString
    }
}
