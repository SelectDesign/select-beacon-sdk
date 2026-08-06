import Foundation

/// Supplies a currently valid, short-lived bearer token to the upload pipeline.
@MainActor
protocol AuthProvider {
    func validToken() async throws -> String
    /// Clears any cached token so the next `validToken()` fetches a new one.
    func invalidateCachedToken()
}

extension AuthProvider {
    func invalidateCachedToken() {}
}

enum UploadResponse: Equatable, Sendable {
    case accepted(acknowledgedIDs: [UUID])
}

@MainActor
protocol UploadTransport {
    func upload(
        detections: [QueuedDetection],
        bearerToken: String
    ) async throws -> UploadResponse
}

/// Placeholder transport until a usable environment base URL is configured.
struct DeferredUploadTransport: UploadTransport {
    struct NotConfigured: Error {}

    func upload(
        detections: [QueuedDetection],
        bearerToken: String
    ) async throws -> UploadResponse {
        _ = detections
        _ = bearerToken
        throw NotConfigured()
    }
}

/// Placeholder auth until a usable environment base URL is configured.
struct DeferredAuthProvider: AuthProvider {
    struct NotConfigured: Error {}

    func validToken() async throws -> String {
        throw NotConfigured()
    }
}

/// Harness auth that always returns a placeholder bearer token.
struct DebugAutoAckAuthProvider: AuthProvider {
    func validToken() async throws -> String {
        "debug-auto-ack-token"
    }
}

/// Harness transport that acknowledges every queued report without network I/O.
struct DebugAutoAckUploadTransport: UploadTransport {
    func upload(
        detections: [QueuedDetection],
        bearerToken: String
    ) async throws -> UploadResponse {
        _ = bearerToken
        return .accepted(acknowledgedIDs: detections.map(\.id))
    }
}
