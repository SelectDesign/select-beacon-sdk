import Foundation

/// A testable abstraction over the subset of `URLSession` used by token retrieval.
protocol HTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionHTTPDataLoader: HTTPDataLoading {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Errors emitted while obtaining an upload token from Select's token broker.
enum TokenBrokerAuthError: Error, Equatable {
    case invalidEndpoint
    case networkRequestFailed
    case invalidHTTPResponse
    /// Auth broker returned HTTP 429; honor `Retry-After` when present.
    case rateLimited(retryAfter: TimeInterval?)
    /// Auth broker rejected credentials or client access (HTTP 401/403).
    ///
    /// May mean bad key/secret or temporary API suspension — hosts see
    /// `.authenticationFailed` while upload keeps retrying with backoff.
    case unauthorized(statusCode: Int)
    case unexpectedStatusCode(Int)
    case invalidResponse

    /// Failures VIP should surface on `operationalStatus` (signal + retry).
    var isHostVisibleAuthenticationFailure: Bool {
        switch self {
        case .unauthorized, .invalidEndpoint, .invalidResponse:
            return true
        case .networkRequestFailed, .invalidHTTPResponse, .rateLimited, .unexpectedStatusCode:
            return false
        }
    }
}

/// Retrieves and retains one short-lived upload token for the app installation.
///
/// The token exists in memory only. This type never writes it to disk or logs it.
@MainActor
final class TokenBrokerAuthProvider: AuthProvider {
    private struct CachedToken {
        let authorization: UploadAuthorization
        let expiresAt: Date
    }

    private struct TokenRequest: Encodable {
        let appKey: String
        let appSecret: String

        enum CodingKeys: String, CodingKey {
            case appKey = "app_key"
            case appSecret = "app_secret"
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let tokenType: String?
        let expiresIn: TimeInterval

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
        }
    }

    private let configuration: TokenBrokerConfiguration
    private let httpClient: HTTPDataLoading
    private let clock: Clock
    private let refreshSafetyMargin: TimeInterval

    private var cachedToken: CachedToken?
    private var refreshTask: Task<UploadAuthorization, Error>?

    init(
        configuration: TokenBrokerConfiguration,
        httpClient: HTTPDataLoading = URLSessionHTTPDataLoader(),
        clock: Clock = SystemClock(),
        refreshSafetyMargin: TimeInterval = 60
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.clock = clock
        self.refreshSafetyMargin = max(0, refreshSafetyMargin)
    }

    func validAuthorization() async throws -> UploadAuthorization {
        if let cachedToken, isUsable(cachedToken) {
            return cachedToken.authorization
        }

        if let refreshTask {
            return try await refreshTask.value
        }

        let refreshTask = Task { @MainActor [weak self] in
            guard let self else {
                throw TokenBrokerAuthError.networkRequestFailed
            }
            return try await self.requestToken()
        }
        self.refreshTask = refreshTask

        do {
            let authorization = try await refreshTask.value
            self.refreshTask = nil
            return authorization
        } catch {
            self.refreshTask = nil
            throw error
        }
    }

    func invalidateCachedToken() {
        cachedToken = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func isUsable(_ token: CachedToken) -> Bool {
        token.expiresAt.timeIntervalSince(clock.now) > refreshSafetyMargin
    }

    private func requestToken() async throws -> UploadAuthorization {
        guard configuration.tokenEndpoint.isUsableHTTPSEndpoint else {
            throw TokenBrokerAuthError.invalidEndpoint
        }

        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            request.httpBody = try JSONEncoder().encode(
                TokenRequest(
                    appKey: configuration.appKey,
                    appSecret: configuration.appSecret
                )
            )
        } catch {
            throw TokenBrokerAuthError.invalidResponse
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            throw TokenBrokerAuthError.networkRequestFailed
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TokenBrokerAuthError.invalidHTTPResponse
        }
        if httpResponse.statusCode == 429 {
            let delay = RetryAfterHeader.delay(
                from: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                now: clock.now
            )
            throw TokenBrokerAuthError.rateLimited(retryAfter: delay)
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw TokenBrokerAuthError.unauthorized(statusCode: httpResponse.statusCode)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw TokenBrokerAuthError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let decodedResponse: TokenResponse
        do {
            decodedResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw TokenBrokerAuthError.invalidResponse
        }

        let token = decodedResponse.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, decodedResponse.expiresIn > 0 else {
            throw TokenBrokerAuthError.invalidResponse
        }

        let authorization = UploadAuthorization(
            accessToken: token,
            tokenType: decodedResponse.tokenType ?? "Bearer"
        )
        cachedToken = CachedToken(
            authorization: authorization,
            expiresAt: clock.now.addingTimeInterval(decodedResponse.expiresIn)
        )
        return authorization
    }
}
