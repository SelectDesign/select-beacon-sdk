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
    case unexpectedStatusCode(Int)
    case invalidResponse
}

/// Retrieves and retains one short-lived upload token for the app installation.
///
/// The token exists in memory only. This type never writes it to disk or logs it.
@MainActor
final class TokenBrokerAuthProvider: AuthProvider {
    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }

    private struct TokenRequest: Encodable {
        let appKey: String

        enum CodingKeys: String, CodingKey {
            case appKey = "app_key"
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private let configuration: TokenBrokerConfiguration
    private let httpClient: HTTPDataLoading
    private let clock: Clock
    private let refreshSafetyMargin: TimeInterval

    private var cachedToken: CachedToken?
    private var refreshTask: Task<String, Error>?

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

    func validToken() async throws -> String {
        if let cachedToken, isUsable(cachedToken) {
            return cachedToken.value
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
            let token = try await refreshTask.value
            self.refreshTask = nil
            return token
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

    private func requestToken() async throws -> String {
        guard let scheme = configuration.tokenEndpoint.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              configuration.tokenEndpoint.host != nil else {
            throw TokenBrokerAuthError.invalidEndpoint
        }

        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            request.httpBody = try JSONEncoder().encode(TokenRequest(appKey: configuration.appKey))
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

        cachedToken = CachedToken(
            value: token,
            expiresAt: clock.now.addingTimeInterval(decodedResponse.expiresIn)
        )
        return token
    }
}
