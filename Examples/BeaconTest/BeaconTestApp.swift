/// Select/debug harness for physical-device validation of SelectBeaconSDK.
///
/// Uses `@_spi(SelectApp)` debug auto-ack — Select only; not for VIP copy-paste.
import SwiftUI
@_spi(SelectApp) import SelectBeaconSDK
import SelectBeaconAppSupport

@main
struct BeaconTestApp: App {
    @StateObject private var model = BeaconTestModel()

    var body: some Scene {
        WindowGroup {
            BeaconTestView(model: model)
        }
    }
}

@MainActor
private final class BeaconTestModel: ObservableObject {
    @Published var activeBeacons: [ActiveBeacon] = []
    @Published var openWindows: [OpenBeaconWindow] = []
    @Published var pendingReports: [PendingBeaconReport] = []
    @Published var deadLetteredReports: [PendingBeaconReport] = []
    @Published var isStopFinalizePending = false
    /// Host intent to run detection (Start tapped, Stop not yet tapped).
    @Published private(set) var wantsRunning = false
    @Published var operationalStatus: SDKOperationalStatus = .unconfigured
    @Published var loadError: String?

    private let support = SelectBeaconAppSupport.shared
    private let observationWindowDuration: TimeInterval = 60

    var canStart: Bool { !isStopFinalizePending && !wantsRunning }

    init() {
        // Register AppSupport listeners before starting so early sightings are not dropped.
        support.onActiveBeaconsChanged = { [weak self] beacons in
            self?.activeBeacons = beacons
        }
        support.onOpenWindowsChanged = { [weak self] windows in
            self?.openWindows = windows
        }
        support.onPendingReportsChanged = { [weak self] reports in
            self?.pendingReports = reports
        }
        support.onDeadLetteredReportsChanged = { [weak self] reports in
            self?.deadLetteredReports = reports
        }
        support.onStopFinalizePendingChanged = { [weak self] pending in
            self?.isStopFinalizePending = pending
        }

        activeBeacons = support.currentBeacons
        openWindows = support.currentOpenWindows
        isStopFinalizePending = support.isStopFinalizePending

        SelectBeaconSDK.configure(
            appKey: "HARNESS_APP_KEY",
            appSecret: "HARNESS_APP_SECRET",
            environment: .staging(baseURL: URL(string: "https://staging.select.example.com")!)
        )
        SelectBeaconSDK.shared.onOperationalStatusChanged = { [weak self] status in
            self?.operationalStatus = status
        }
        operationalStatus = SelectBeaconSDK.shared.operationalStatus
        // Demo-only: acknowledge flushed batches without calling the live broker/ingest.
        // For real staging auth E2E, remove this and use provisioned appKey/appSecret.
        SelectBeaconSDK.shared.selectInstallDebugAutoAckUploadSeams()
        start()

        Task {
            do {
                pendingReports = try await support.pendingReports()
                deadLetteredReports = try await support.deadLetteredReports()
            } catch {
                loadError = String(describing: error)
            }
        }
    }

    func start() {
        guard canStart else { return }
        SelectBeaconSDK.shared.start()
        wantsRunning = true
        operationalStatus = SelectBeaconSDK.shared.operationalStatus
    }

    func stop() {
        guard wantsRunning else { return }
        SelectBeaconSDK.shared.stop()
        wantsRunning = false
        isStopFinalizePending = support.isStopFinalizePending
        operationalStatus = SelectBeaconSDK.shared.operationalStatus
    }

    var canClearQueues: Bool { !wantsRunning && !isStopFinalizePending }

    func clearPendingReports() {
        guard canClearQueues else { return }
        Task {
            do {
                try await support.clearPendingReports()
                pendingReports = try await support.pendingReports()
            } catch {
                loadError = String(describing: error)
            }
        }
    }

    func clearDeadLetteredReports() {
        guard canClearQueues else { return }
        Task {
            do {
                try await support.clearDeadLetteredReports()
                deadLetteredReports = try await support.deadLetteredReports()
            } catch {
                loadError = String(describing: error)
            }
        }
    }

    func secondsRemaining(in window: OpenBeaconWindow, at now: Date) -> Int {
        let deadline = window.windowStartedAt.addingTimeInterval(observationWindowDuration)
        return max(0, Int(deadline.timeIntervalSince(now).rounded(.down)))
    }
}

private struct BeaconTestView: View {
    @ObservedObject var model: BeaconTestModel

    var body: some View {
        NavigationStack {
            List {
                sessionSection

                if let loadError = model.loadError {
                    Section("Error") {
                        Text(loadError)
                            .foregroundStyle(.red)
                    }
                }

                Section("In range") {
                    if model.activeBeacons.isEmpty {
                        Text("No beacons nearby")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.activeBeacons, id: \.identityKey) { beacon in
                            BeaconIdentityRow(
                                major: beacon.major,
                                minor: beacon.minor,
                                detail: "RSSI \(beacon.rssi) dBm",
                                caption: "Last seen \(beacon.lastObservedAt.formatted())"
                            )
                        }
                    }
                }

                Section("Open summaries") {
                    if model.openWindows.isEmpty {
                        Text("No open observation windows")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.openWindows, id: \.identityKey) { window in
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let remaining = model.secondsRemaining(in: window, at: context.date)
                                BeaconIdentityRow(
                                    major: window.major,
                                    minor: window.minor,
                                    detail: "Best RSSI \(window.bestRSSI) · \(window.observationCount) sightings",
                                    caption: "\(remaining)s remaining · started \(window.windowStartedAt.formatted(date: .omitted, time: .standard))",
                                    locationText: locationCaption(window.location, includeAccuracy: true)
                                )
                            }
                        }
                    }
                }

                Section("Queued for upload") {
                    if model.pendingReports.isEmpty {
                        Text("Queue empty")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.pendingReports, id: \.id) { report in
                            BeaconIdentityRow(
                                major: report.major,
                                minor: report.minor,
                                detail: "Best RSSI \(report.bestRSSI) · \(report.observationCount) sightings",
                                caption: "Queued \(report.queuedAt.formatted())",
                                locationText: locationCaption(report.location, includeAccuracy: false)
                            )
                        }
                    }
                }

                Section("Dead letter") {
                    Text("Not re-uploaded after non-retryable failure or max attempts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.deadLetteredReports.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.deadLetteredReports, id: \.id) { report in
                            BeaconIdentityRow(
                                major: report.major,
                                minor: report.minor,
                                detail: "Best RSSI \(report.bestRSSI) · \(report.observationCount) sightings",
                                caption: "Queued \(report.queuedAt.formatted())",
                                locationText: locationCaption(report.location, includeAccuracy: false)
                            )
                        }
                    }
                }
            }
            .navigationTitle("BeaconTest")
        }
    }

    private var sessionSection: some View {
        Section("Session") {
            Text(sessionStatusTitle)
                .foregroundStyle(model.isStopFinalizePending ? .orange : .primary)
            Text(sessionStatusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Start") { model.start() }
                    .disabled(!model.canStart)
                Button("Stop") { model.stop() }
                    .disabled(!model.wantsRunning)
            }

            HStack {
                Button("Clear Queue") { model.clearPendingReports() }
                    .disabled(!model.canClearQueues || model.pendingReports.isEmpty)
                Button("Clear Dead Letter") { model.clearDeadLetteredReports() }
                    .disabled(!model.canClearQueues || model.deadLetteredReports.isEmpty)
            }
        }
    }

    private var sessionStatusTitle: String {
        if model.isStopFinalizePending {
            return "Finalizing stop…"
        }
        switch model.operationalStatus {
        case .unconfigured:
            return "Unconfigured"
        case .ready:
            return model.wantsRunning ? "Ready" : "Stopped"
        case .awaitingPermission:
            return "Awaiting permission"
        case .paused:
            return "Paused"
        case .ranging:
            return "Ranging"
        case .degraded(let issue):
            switch issue {
            case .authenticationFailed:
                return "Authentication failed"
            default:
                return "Degraded (\(String(describing: issue)))"
            }
        }
    }

    private var sessionStatusDetail: String {
        if model.isStopFinalizePending {
            return "Open windows clear before disk enqueue finishes. Start stays gated."
        }
        switch model.operationalStatus {
        case .ranging:
            return "Core Location ranging is active."
        case .paused:
            return "Detection requested but inactive (foreground/permission)."
        case .awaitingPermission:
            return "Host must grant location authorization."
        case .ready where model.wantsRunning:
            return "Start requested; waiting for ranging conditions."
        case .ready, .unconfigured:
            return "Call Start to begin detection."
        case .degraded(.authenticationFailed):
            return "Token broker failed; Queued retained and upload retries. Clears on successful mint."
        case .degraded:
            return "See operationalStatus for the recoverable issue."
        }
    }

    private func locationCaption(_ location: LocationFix?, includeAccuracy: Bool) -> String {
        guard let location else { return "Location unavailable" }
        let cachedTime = "Cached location time \(location.timestamp.formatted(date: .omitted, time: .standard))"
        if includeAccuracy {
            return String(
                format: "Location %.5f, %.5f (±%.0fm) · %@",
                location.latitude,
                location.longitude,
                location.horizontalAccuracy,
                cachedTime
            )
        }
        return String(
            format: "Location %.5f, %.5f · %@",
            location.latitude,
            location.longitude,
            cachedTime
        )
    }
}

private struct BeaconIdentityRow: View {
    let major: Int
    let minor: Int
    let detail: String
    let caption: String
    var locationText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Major \(major) · Minor \(minor)")
                .font(.headline)
            Text(detail)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let locationText {
                Text(locationText)
                    .font(.caption)
                    .foregroundStyle(locationText == "Location unavailable" ? .secondary : .primary)
            }
        }
    }
}

private extension ActiveBeacon {
    var identityKey: String { "\(uuid.uuidString)-\(major)-\(minor)" }
}

private extension OpenBeaconWindow {
    var identityKey: String { "\(uuid.uuidString)-\(major)-\(minor)" }
}
