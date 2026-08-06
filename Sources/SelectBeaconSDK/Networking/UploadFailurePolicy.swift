import Foundation

/// Coordinator-facing policy derived from transport / auth failures.
enum UploadFailurePolicy: Equatable, Sendable {
    case retryable(backoff: RetryBackoffKind)
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
                return .retryable(backoff: .rateLimited(retryAfter: retryAfter))
            case .unauthorized:
                return .unauthorizedRefresh
            case .clientError:
                return .deadLetterImmediately
            case .serverError, .networkRequestFailed, .invalidHTTPResponse,
                 .invalidEndpoint, .missingDeviceIdentifier:
                return .retryable(backoff: .exponential)
            }
        }
        // Token acquisition and other failures are retryable.
        return .retryable(backoff: .exponential)
    }
}
