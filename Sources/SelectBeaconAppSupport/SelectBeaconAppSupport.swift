/// Select-owned views over beacon data held by `SelectBeaconSDK`.
///
/// This target is the only normal consumer of the core module's `SelectApp`
/// SPI. App code imports this product rather than using `@_spi` itself.
@_spi(SelectApp) import SelectBeaconSDK
import Foundation

@MainActor
public final class SelectBeaconAppSupport {
    /// The adapter instance for apps using `SelectBeaconSDK.shared`.
    public static let shared = SelectBeaconAppSupport(sdk: .shared)

    /// Beacons observed within the SDK's absence timeout.
    ///
    /// This is a synchronous in-memory snapshot ordered by UUID, then major,
    /// then minor so list UIs stay stable when only RSSI or last-seen changes.
    /// It is appropriate for rendering the current UI, but is not a history and
    /// does not imply that the beacon produced an API report.
    public private(set) var currentBeacons: [ActiveBeacon]

    /// Open observation windows with running aggregates (not yet queued).
    public private(set) var currentOpenWindows: [OpenBeaconWindow]

    /// True while a `stop()`-initiated finalize enqueue is still writing to disk.
    ///
    /// Empty `currentOpenWindows` after `stop()` is not sufficient to prove
    /// durable enqueue finished. Gate Start on this flag becoming `false`.
    public private(set) var isStopFinalizePending: Bool

    /// Called with a complete replacement snapshot whenever beacon presence changes.
    ///
    /// Snapshots are ordered by UUID, then major, then minor. Register this
    /// before starting the SDK, then also read `currentBeacons` immediately to
    /// avoid missing state that existed before registration.
    public var onActiveBeaconsChanged: (([ActiveBeacon]) -> Void)?

    /// Called whenever open observation-window aggregates change.
    public var onOpenWindowsChanged: (([OpenBeaconWindow]) -> Void)?

    /// Called with the complete FIFO durable queue after enqueue or upload ack.
    ///
    /// This is a change notification, not an initial replay. Call
    /// `pendingReports()` during application startup to load records persisted
    /// by an earlier process.
    public var onPendingReportsChanged: (([PendingBeaconReport]) -> Void)?

    /// Called with the complete dead-lettered queue after upload ack or dead-letter.
    ///
    /// Dead-lettered reports are retained for diagnostics and are not
    /// re-uploaded. This is a change notification, not an initial replay. Call
    /// `deadLetteredReports()` during application startup to load records
    /// persisted by an earlier process. `clearPendingReports()` does not clear
    /// dead letters; use `clearDeadLetteredReports()` for that.
    public var onDeadLetteredReportsChanged: (([PendingBeaconReport]) -> Void)?

    /// Called whenever `isStopFinalizePending` changes.
    ///
    /// This is a change notification, not an initial replay. Read
    /// `isStopFinalizePending` immediately after registration.
    public var onStopFinalizePendingChanged: ((Bool) -> Void)?

    private let sdk: SelectBeaconSDK

    init(sdk: SelectBeaconSDK) {
        // The adapter uses the same core instance as the application. Assigning
        // these callbacks is safe because both modules are main-actor isolated.
        self.sdk = sdk
        currentBeacons = sdk.selectActiveBeaconObservations.map { ActiveBeacon($0) }
        currentOpenWindows = sdk.selectOpenWindowSnapshots.map { OpenBeaconWindow($0) }
        isStopFinalizePending = sdk.selectIsStopFinalizePending
        sdk.onSelectActiveBeaconsChanged = { [weak self] observations in
            self?.publishActiveBeacons(observations)
        }
        sdk.onSelectOpenWindowsChanged = { [weak self] windows in
            self?.publishOpenWindows(windows)
        }
        sdk.onSelectPendingReportsChanged = { [weak self] reports in
            self?.onPendingReportsChanged?(reports.map { PendingBeaconReport($0) })
        }
        sdk.onSelectDeadLetteredReportsChanged = { [weak self] reports in
            self?.onDeadLetteredReportsChanged?(reports.map { PendingBeaconReport($0) })
        }
        sdk.onSelectStopFinalizePendingChanged = { [weak self] pending in
            self?.publishStopFinalizePending(pending)
        }
    }

    /// Returns the complete FIFO set of reports awaiting upload acknowledgement.
    ///
    /// The method is async because the core queue is actor-isolated and may
    /// need to read the persisted JSON file. `throws` preserves corruption or
    /// I/O failures instead of silently showing an empty report list.
    public func pendingReports() async throws -> [PendingBeaconReport] {
        let reports = try await sdk.selectPendingReports()
        return reports.map { PendingBeaconReport($0) }
    }

    /// Returns reports removed from the pending FIFO after non-retryable failure
    /// or max upload attempts.
    ///
    /// Dead-lettered records are not re-uploaded. The store is bounded by the
    /// same max size/age as pending. `clearPendingReports()` does not clear
    /// this list — use `clearDeadLetteredReports()`. The method is async and
    /// may throw for the same durable-store reasons as `pendingReports()`.
    public func deadLetteredReports() async throws -> [PendingBeaconReport] {
        let reports = try await sdk.selectDeadLetteredReports()
        return reports.map { PendingBeaconReport($0) }
    }

    /// Empties the durable pending queue and publishes `onPendingReportsChanged([])`.
    ///
    /// Hosts must stop detection first and wait until `isStopFinalizePending`
    /// is false. This overwrites corrupted queue payloads so an unreadable
    /// queue can be recovered without deleting the app. Dead-lettered reports
    /// are left unchanged.
    public func clearPendingReports() async throws {
        do {
            try await sdk.selectClearPendingReports()
        } catch let error as SelectPendingReportsClearError {
            throw mapClearError(error)
        }
    }

    /// Empties the durable dead-letter store and publishes
    /// `onDeadLetteredReportsChanged([])`.
    ///
    /// Same gates as `clearPendingReports()` (configured, detection stopped,
    /// stop-finalize settled). Does not clear pending reports.
    public func clearDeadLetteredReports() async throws {
        do {
            try await sdk.selectClearDeadLetteredReports()
        } catch let error as SelectPendingReportsClearError {
            throw mapClearError(error)
        }
    }

    private func mapClearError(_ error: SelectPendingReportsClearError) -> PendingReportsClearError {
        switch error {
        case .notConfigured:
            return .notConfigured
        case .detectionActive:
            return .detectionActive
        case .stopFinalizePending:
            return .stopFinalizePending
        }
    }

    private func publishActiveBeacons(_ observations: [BeaconObservation]) {
        let beacons = observations.map { ActiveBeacon($0) }
        currentBeacons = beacons
        onActiveBeaconsChanged?(beacons)
    }

    private func publishOpenWindows(_ windows: [SelectOpenBeaconWindow]) {
        let mapped = windows.map { OpenBeaconWindow($0) }
        currentOpenWindows = mapped
        onOpenWindowsChanged?(mapped)
    }

    private func publishStopFinalizePending(_ pending: Bool) {
        guard isStopFinalizePending != pending else { return }
        isStopFinalizePending = pending
        onStopFinalizePendingChanged?(pending)
    }
}

/// The latest observation for a Select beacon currently considered in range.
///
/// `uuid`, `major`, and `minor` form the beacon identity. RSSI is a momentary
/// radio-strength estimate in dBm, not a distance measurement.
public struct ActiveBeacon: Equatable, Sendable {
    public let uuid: UUID
    public let major: Int
    public let minor: Int
    public let rssi: Int
    public let lastObservedAt: Date

    init(_ observation: BeaconObservation) {
        uuid = observation.uuid
        major = observation.major
        minor = observation.minor
        rssi = observation.rssi
        lastObservedAt = observation.observedAt
    }
}

/// Running aggregates for an open 60-second observation window.
public struct OpenBeaconWindow: Equatable, Sendable {
    public let uuid: UUID
    public let major: Int
    public let minor: Int
    public let bestRSSI: Int
    public let latestTimestamp: Date
    public let windowStartedAt: Date
    public let observationCount: Int
    public let location: LocationFix?

    init(_ window: SelectOpenBeaconWindow) {
        uuid = window.uuid
        major = window.major
        minor = window.minor
        bestRSSI = window.bestRSSI
        latestTimestamp = window.latestTimestamp
        windowStartedAt = window.windowStartedAt
        observationCount = window.observationCount
        location = window.location
    }
}

/// A durable observation-window report awaiting upload acknowledgement.
///
/// `id` is the queue record identity, while UUID/major/minor identify the
/// physical beacon. `location` may be nil when no fix was available.
public struct PendingBeaconReport: Equatable, Sendable {
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

    init(_ report: SelectPendingBeaconReport) {
        id = report.id
        uuid = report.uuid
        major = report.major
        minor = report.minor
        bestRSSI = report.bestRSSI
        latestTimestamp = report.latestTimestamp
        windowStartedAt = report.windowStartedAt
        observationCount = report.observationCount
        location = report.location
        queuedAt = report.queuedAt
    }
}

/// Why `clearPendingReports()` or `clearDeadLetteredReports()` refused to run.
public enum PendingReportsClearError: Error, Equatable, Sendable {
    /// `SelectBeaconSDK.configure` has not succeeded for this process.
    case notConfigured
    /// Detection intent is still on — stop first.
    case detectionActive
    /// A prior `stop()` finalize enqueue is still writing to disk.
    case stopFinalizePending
}
