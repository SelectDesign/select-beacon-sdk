import Foundation

/// One detection in the ingest body (kebab-case on the wire).
///
/// `idempotencyKey` is the durable queue record id. It is stable across retries
/// so the ingest API can dedupe at-least-once re-sends.
struct BeaconUploadDetection: Encodable, Equatable, Sendable {
    let uuid: UUID
    let major: Int
    let minor: Int
    let bestRssiDbm: Int
    let observations: Int
    let lat: Double?
    let lng: Double?
    let firstSeen: Date
    let lastSeen: Date
    let deviceId: String
    /// Stable per durable queue record; identical on every re-send of that record.
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case uuid
        case major
        case minor
        case bestRssiDbm = "best-rssi-dbm"
        case observations
        case lat
        case lng
        case firstSeen = "first-seen"
        case lastSeen = "last-seen"
        case deviceId = "device-id"
        case idempotencyKey = "idempotency-key"
    }

    init(detection: QueuedDetection, deviceId: String) {
        uuid = detection.uuid
        major = detection.major
        minor = detection.minor
        bestRssiDbm = detection.bestRSSI
        observations = detection.observationCount
        lat = detection.location?.latitude
        lng = detection.location?.longitude
        firstSeen = detection.windowStartedAt
        lastSeen = detection.latestTimestamp
        self.deviceId = deviceId
        idempotencyKey = detection.id.uuidString
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(major, forKey: .major)
        try container.encode(minor, forKey: .minor)
        try container.encode(bestRssiDbm, forKey: .bestRssiDbm)
        try container.encode(observations, forKey: .observations)
        if let lat {
            try container.encode(lat, forKey: .lat)
        } else {
            try container.encodeNil(forKey: .lat)
        }
        if let lng {
            try container.encode(lng, forKey: .lng)
        } else {
            try container.encodeNil(forKey: .lng)
        }
        try container.encode(firstSeen, forKey: .firstSeen)
        try container.encode(lastSeen, forKey: .lastSeen)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
    }
}

/// Document posted to `/ingest/sdk/v1/detections`.
struct BeaconUploadDocument: Encodable, Equatable, Sendable {
    let detections: [BeaconUploadDetection]
}

/// Builds the ingest body a live HTTP upload transport will POST.
struct BeaconUploadPayloadEncoder {
    struct MissingDeviceIdentifier: Error {}

    private let encoder: JSONEncoder

    init(encoder: JSONEncoder = BeaconUploadPayloadEncoder.makeJSONEncoder()) {
        self.encoder = encoder
    }

    static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func document(
        from detections: [QueuedDetection],
        deviceId: String
    ) -> BeaconUploadDocument {
        BeaconUploadDocument(
            detections: detections.map { BeaconUploadDetection(detection: $0, deviceId: deviceId) }
        )
    }

    /// Encodes `{ "detections": [ flat detection objects… ] }`.
    ///
    /// Throws `MissingDeviceIdentifier` when `deviceId` is nil or empty so the
    /// upload path never sends a body without a vendor device id.
    func encode(_ detections: [QueuedDetection], deviceId: String?) throws -> Data {
        guard let deviceId, !deviceId.isEmpty else {
            throw MissingDeviceIdentifier()
        }
        return try encoder.encode(document(from: detections, deviceId: deviceId))
    }
}
