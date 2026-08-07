import Foundation

/// Internal aliases for the public diagnostics types.
typealias DiagnosticEvent = SelectBeaconDiagnosticEvent
typealias DiagnosticsReporting = SelectBeaconDiagnosticsReporting

/// Marker used when a diagnostic has no underlying failure (e.g. intentional eviction).
struct DiagnosticNotice: Error, Equatable, Sendable {
    let detail: String

    init(_ detail: String = "") {
        self.detail = detail
    }
}

/// Drops all diagnostic events (default when no host reporter is installed).
final class NoopDiagnosticsReporter: SelectBeaconDiagnosticsReporting {
    init() {}

    func record(_ event: SelectBeaconDiagnosticEvent, error: Error) {}
}

/// Forwards to a swappable host sink so UploadCoordinator can keep one reporter reference.
@MainActor
final class ForwardingDiagnosticsReporter: SelectBeaconDiagnosticsReporting {
    var target: (any SelectBeaconDiagnosticsReporting)?

    init(target: (any SelectBeaconDiagnosticsReporting)? = nil) {
        self.target = target
    }

    func record(_ event: SelectBeaconDiagnosticEvent, error: Error) {
        target?.record(event, error: error)
    }
}
