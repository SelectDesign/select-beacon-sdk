import Foundation

/// Outcome of classifying an ingest HTTP status for upload retry policy.
enum HTTPIngestStatusClassification: Equatable, Sendable {
    case success
    case rateLimited(retryAfter: TimeInterval?)
    case unauthorized(statusCode: Int)
    case clientError(statusCode: Int)
    case serverError(statusCode: Int)
}

/// Pure mapping from ingest HTTP status (+ optional Retry-After) to a typed outcome.
enum HTTPIngestStatusClassifier {
    static func classify(
        statusCode: Int,
        retryAfterHeader: String?,
        now: Date = Date()
    ) -> HTTPIngestStatusClassification {
        if statusCode == 200 {
            return .success
        }
        if statusCode == 429 {
            let delay = RetryAfterHeader.delay(from: retryAfterHeader, now: now)
            return .rateLimited(retryAfter: delay)
        }
        if statusCode == 401 || statusCode == 403 {
            return .unauthorized(statusCode: statusCode)
        }
        if (400..<500).contains(statusCode) {
            return .clientError(statusCode: statusCode)
        }
        if (500..<600).contains(statusCode) {
            return .serverError(statusCode: statusCode)
        }
        // Non-standard codes: treat as retryable server-side failure.
        return .serverError(statusCode: statusCode)
    }
}
