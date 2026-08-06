import Foundation

enum HTTPIngestUploadError: Error, Equatable {
    case invalidEndpoint
    case missingDeviceIdentifier
    case networkRequestFailed
    case invalidHTTPResponse
    case rateLimited(retryAfter: TimeInterval?)
    case unauthorized(statusCode: Int)
    case clientError(statusCode: Int)
    case serverError(statusCode: Int)
}

/// Posts `{ "detections": [ … ] }` to `/ingest/sdk/v1/detections`.
///
/// HTTP 200 acknowledges the entire posted batch (local queue IDs).
@MainActor
final class HTTPIngestUploadTransport: UploadTransport {
    static let jsonContentType = "application/json"

    private let ingestURL: URL
    private let httpClient: HTTPDataLoading
    private let deviceIdentifier: DeviceIdentifying
    private let payloadEncoder: BeaconUploadPayloadEncoder
    private let clock: Clock

    init(
        ingestURL: URL,
        httpClient: HTTPDataLoading = URLSessionHTTPDataLoader(),
        deviceIdentifier: DeviceIdentifying,
        payloadEncoder: BeaconUploadPayloadEncoder = BeaconUploadPayloadEncoder(),
        clock: Clock = SystemClock()
    ) {
        self.ingestURL = ingestURL
        self.httpClient = httpClient
        self.deviceIdentifier = deviceIdentifier
        self.payloadEncoder = payloadEncoder
        self.clock = clock
    }

    func upload(
        detections: [QueuedDetection],
        bearerToken: String
    ) async throws -> UploadResponse {
        guard let scheme = ingestURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              ingestURL.host != nil else {
            throw HTTPIngestUploadError.invalidEndpoint
        }

        let body: Data
        do {
            body = try payloadEncoder.encode(detections, deviceId: deviceIdentifier.deviceId)
        } catch is BeaconUploadPayloadEncoder.MissingDeviceIdentifier {
            throw HTTPIngestUploadError.missingDeviceIdentifier
        } catch {
            throw HTTPIngestUploadError.networkRequestFailed
        }

        var request = URLRequest(url: ingestURL)
        request.httpMethod = "POST"
        request.setValue(Self.jsonContentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.jsonContentType, forHTTPHeaderField: "Accept")
        if UploadAuthentication.isEnabled, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        let response: URLResponse
        do {
            (_, response) = try await httpClient.data(for: request)
        } catch {
            throw HTTPIngestUploadError.networkRequestFailed
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPIngestUploadError.invalidHTTPResponse
        }

        switch HTTPIngestStatusClassifier.classify(
            statusCode: httpResponse.statusCode,
            retryAfterHeader: httpResponse.value(forHTTPHeaderField: "Retry-After"),
            now: clock.now
        ) {
        case .success:
            return .accepted(acknowledgedIDs: detections.map(\.id))
        case .rateLimited(let retryAfter):
            throw HTTPIngestUploadError.rateLimited(retryAfter: retryAfter)
        case .unauthorized(let statusCode):
            throw HTTPIngestUploadError.unauthorized(statusCode: statusCode)
        case .clientError(let statusCode):
            throw HTTPIngestUploadError.clientError(statusCode: statusCode)
        case .serverError(let statusCode):
            throw HTTPIngestUploadError.serverError(statusCode: statusCode)
        }
    }
}
