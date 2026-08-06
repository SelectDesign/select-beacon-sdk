import Foundation

enum DiagnosticEvent: Equatable {
    case durableQueueWriteFailed
    case durableQueueUnreadable
    case uploadFailed
    case deviceIdentifierUnavailable
    case uploadDeadLettered
    case durableQueueEvicted
}

/// Marker used when a diagnostic has no underlying failure (e.g. intentional eviction).
struct DiagnosticNotice: Error, Equatable {
    let detail: String

    init(_ detail: String = "") {
        self.detail = detail
    }
}

/// Internal diagnostics seam for tests and future host injection (e.g. Sentry).
/// Not part of the standard public SDK surface.
protocol DiagnosticsReporting {
    func record(_ event: DiagnosticEvent, error: Error)
}

extension DiagnosticsReporting {
    func record(_ event: DiagnosticEvent) {
        record(event, error: DiagnosticNotice())
    }
}

struct NoopDiagnosticsReporter: DiagnosticsReporting {
    func record(_ event: DiagnosticEvent, error: Error) {}
}
