import Foundation

enum HTTPIngestUploadError: Error, Equatable {
    case invalidEndpoint
    case missingDeviceIdentifier
    case networkRequestFailed
    case invalidHTTPResponse
    case unexpectedStatusCode(Int)
}

/// Posts a JSON:API `sdk_beacon` document to `/ingest/sdk/v1`.
///
/// HTTP 200 acknowledges the entire posted batch (local queue IDs).
@MainActor
final class HTTPIngestUploadTransport: UploadTransport {
    static let jsonAPIContentType = "application/vnd.api+json"

    private let ingestURL: URL
    private let httpClient: HTTPDataLoading
    private let deviceIdentifier: DeviceIdentifying
    private let payloadEncoder: BeaconUploadPayloadEncoder

    init(
        ingestURL: URL,
        httpClient: HTTPDataLoading = URLSessionHTTPDataLoader(),
        deviceIdentifier: DeviceIdentifying,
        payloadEncoder: BeaconUploadPayloadEncoder = BeaconUploadPayloadEncoder()
    ) {
        self.ingestURL = ingestURL
        self.httpClient = httpClient
        self.deviceIdentifier = deviceIdentifier
        self.payloadEncoder = payloadEncoder
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
        request.setValue(Self.jsonAPIContentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.jsonAPIContentType, forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
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
        guard httpResponse.statusCode == 200 else {
            throw HTTPIngestUploadError.unexpectedStatusCode(httpResponse.statusCode)
        }

        return .accepted(acknowledgedIDs: detections.map(\.id))
    }
}
