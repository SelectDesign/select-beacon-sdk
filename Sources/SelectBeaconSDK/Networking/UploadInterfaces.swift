import Foundation

/// Short-lived credentials used for authenticated ingest requests.
struct UploadAuthorization: Equatable, Sendable {
    let accessToken: String
    let tokenType: String

    /// Value for the HTTP `Authorization` header.
    var headerValue: String {
        "\(tokenType) \(accessToken)"
    }

    init(accessToken: String, tokenType: String = "Bearer") {
        self.accessToken = accessToken
        let trimmedType = tokenType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tokenType = trimmedType.isEmpty ? "Bearer" : trimmedType
    }
}

/// Supplies currently valid upload authorization to the upload pipeline.
@MainActor
protocol AuthProvider {
    func validAuthorization() async throws -> UploadAuthorization
    /// Clears any cached token so the next `validAuthorization()` fetches a new one.
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
        authorization: UploadAuthorization
    ) async throws -> UploadResponse
}

/// Placeholder transport until a usable environment base URL is configured.
struct DeferredUploadTransport: UploadTransport {
    struct NotConfigured: Error {}

    func upload(
        detections: [QueuedDetection],
        authorization: UploadAuthorization
    ) async throws -> UploadResponse {
        _ = detections
        _ = authorization
        throw NotConfigured()
    }
}

/// Placeholder auth until a usable environment base URL is configured.
struct DeferredAuthProvider: AuthProvider {
    struct NotConfigured: Error {}

    func validAuthorization() async throws -> UploadAuthorization {
        throw NotConfigured()
    }
}

/// Harness auth that always returns a placeholder bearer token.
struct DebugAutoAckAuthProvider: AuthProvider {
    func validAuthorization() async throws -> UploadAuthorization {
        UploadAuthorization(accessToken: "debug-auto-ack-token")
    }
}

/// Harness transport that acknowledges every queued report without network I/O.
struct DebugAutoAckUploadTransport: UploadTransport {
    func upload(
        detections: [QueuedDetection],
        authorization: UploadAuthorization
    ) async throws -> UploadResponse {
        _ = authorization
        return .accepted(acknowledgedIDs: detections.map(\.id))
    }
}
