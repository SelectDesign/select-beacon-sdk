import Foundation

/// Coordinator-facing policy derived from transport / auth failures.
enum UploadFailurePolicy: Equatable, Sendable {
    case retryable(backoff: RetryBackoffKind, consumesUploadAttempt: Bool)
    case unauthorizedRefresh
    case deadLetterImmediately

    enum RetryBackoffKind: Equatable, Sendable {
        case exponential
        case rateLimited(retryAfter: TimeInterval?)
    }

    static func policy(for error: Error) -> UploadFailurePolicy {
        if let ingest = error as? HTTPIngestUploadError {
            switch ingest {
            case .rateLimited(let retryAfter):
                return .retryable(
                    backoff: .rateLimited(retryAfter: retryAfter),
                    consumesUploadAttempt: true
                )
            case .unauthorized:
                return .unauthorizedRefresh
            case .clientError:
                return .deadLetterImmediately
            case .serverError, .networkRequestFailed, .invalidHTTPResponse,
                 .invalidEndpoint, .missingDeviceIdentifier:
                return .retryable(backoff: .exponential, consumesUploadAttempt: true)
            }
        }
        if let auth = error as? TokenBrokerAuthError {
            switch auth {
            case .rateLimited(let retryAfter):
                // Broker suspension / rate limits must not burn upload attempts
                // or dead-letter Queued work before re-enable can self-heal.
                return .retryable(
                    backoff: .rateLimited(retryAfter: retryAfter),
                    consumesUploadAttempt: false
                )
            case .invalidEndpoint, .networkRequestFailed, .invalidHTTPResponse,
                 .unexpectedStatusCode, .invalidResponse:
                return .retryable(backoff: .exponential, consumesUploadAttempt: false)
            }
        }
        // Unknown failures are retryable with exponential backoff.
        return .retryable(backoff: .exponential, consumesUploadAttempt: true)
    }
}
