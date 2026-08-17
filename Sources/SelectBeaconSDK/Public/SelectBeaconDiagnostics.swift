import Foundation

/// Coarse, non-sensitive diagnostic events emitted by the SDK.
///
/// Hosts may forward these to their own monitoring stack. Do not attach tokens,
/// secrets, full HTTP payloads, or beacon identities when logging.
public enum SelectBeaconDiagnosticEvent: Equatable, Sendable {
    /// Durable pending or dead-letter persist failed.
    case durableQueueWriteFailed
    /// On-disk queue JSON could not be decoded.
    case durableQueueUnreadable
    /// An upload attempt failed (retryable or otherwise classified upstream).
    ///
    /// The associated `error` may carry a coarse, non-sensitive triage hint for
    /// host monitoring (token-broker vs ingest). Never log tokens, secrets, or
    /// HTTP bodies from this error.
    case uploadFailed
    /// IDFV / device id was unavailable when building an ingest batch.
    case deviceIdentifierUnavailable
    /// A batch was moved to the dead-letter store.
    case uploadDeadLettered
    /// Pending or dead-letter retention dropped one or more records.
    case durableQueueEvicted
}

/// Host-provided sink for SDK diagnostic events.
///
/// Install with `SelectBeaconSDK.shared.setDiagnosticsReporter(_:)`. The SDK
/// never ships a monitoring client; forward events to whatever the host uses.
/// Treat `error` as opaque typing context — do not log secrets or full payloads.
@MainActor
public protocol SelectBeaconDiagnosticsReporting: AnyObject {
    func record(_ event: SelectBeaconDiagnosticEvent, error: Error)
}

extension SelectBeaconDiagnosticsReporting {
    public func record(_ event: SelectBeaconDiagnosticEvent) {
        record(event, error: DiagnosticNotice())
    }
}
