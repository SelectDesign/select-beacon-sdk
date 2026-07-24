import Foundation

enum DiagnosticEvent: Equatable {
    case durableQueueWriteFailed
    case durableQueueUnreadable
    case uploadFailed
    case deviceIdentifierUnavailable
}

/// Host applications can bridge this internal seam to Sentry without adding a dependency to the SDK.
protocol DiagnosticsReporting {
    func record(_ event: DiagnosticEvent, error: Error)
}

struct NoopDiagnosticsReporter: DiagnosticsReporting {
    func record(_ event: DiagnosticEvent, error: Error) {}
}
