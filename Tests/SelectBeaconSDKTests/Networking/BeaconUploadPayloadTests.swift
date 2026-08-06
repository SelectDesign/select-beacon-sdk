import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

final class BeaconUploadPayloadTests: XCTestCase {
    private let fleetUUID = SDKConfiguration.default.monitoredUUIDs[0]
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    private let deviceId = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"

    func testEncodeDocumentUsesFlatDetectionsAndSnakeCaseKeys() throws {
        let detection = QueuedDetection(
            uuid: fleetUUID,
            major: 1,
            minor: 42,
            bestRSSI: -55,
            latestTimestamp: timestamp,
            windowStartedAt: timestamp.addingTimeInterval(-30),
            observationCount: 4,
            location: LocationFix(
                latitude: 40.7128,
                longitude: -74.006,
                horizontalAccuracy: 100,
                timestamp: timestamp
            ),
            queuedAt: timestamp
        )
        let data = try BeaconUploadPayloadEncoder().encode([detection], deviceId: deviceId)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let detections = try XCTUnwrap(json["detections"] as? [[String: Any]])
        XCTAssertEqual(detections.count, 1)
        let item = try XCTUnwrap(detections.first)
        XCTAssertNil(item["type"])
        XCTAssertNil(item["attributes"])
        XCTAssertEqual(Set(item.keys), [
            "uuid", "major", "minor", "best_rssi_dbm", "observations",
            "lat", "lng", "first_seen", "last_seen", "device_id", "idempotency_key",
        ])
        XCTAssertEqual(item["uuid"] as? String, fleetUUID.uuidString)
        XCTAssertEqual(item["major"] as? Int, 1)
        XCTAssertEqual(item["minor"] as? Int, 42)
        XCTAssertEqual(item["best_rssi_dbm"] as? Int, -55)
        XCTAssertEqual(item["observations"] as? Int, 4)
        XCTAssertEqual(item["lat"] as? Double, 40.7128)
        XCTAssertEqual(item["lng"] as? Double, -74.006)
        XCTAssertEqual(item["device_id"] as? String, deviceId)
        XCTAssertEqual(item["idempotency_key"] as? String, detection.id.uuidString)
        XCTAssertEqual(item["first_seen"] as? String, "2023-11-14T22:12:50Z")
        XCTAssertEqual(item["last_seen"] as? String, "2023-11-14T22:13:20Z")
    }

    func testEncodeRecordWithoutLocationUsesNullLatLng() throws {
        let detection = QueuedDetection(
            uuid: fleetUUID,
            major: 1,
            minor: 7,
            bestRSSI: -70,
            latestTimestamp: timestamp,
            windowStartedAt: timestamp,
            observationCount: 1,
            location: nil,
            queuedAt: timestamp
        )
        let data = try BeaconUploadPayloadEncoder().encode([detection], deviceId: deviceId)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let detections = try XCTUnwrap(json["detections"] as? [[String: Any]])
        let item = try XCTUnwrap(detections.first)
        XCTAssertTrue(item["lat"] is NSNull)
        XCTAssertTrue(item["lng"] is NSNull)
        XCTAssertEqual(item["device_id"] as? String, deviceId)
    }

    func testEncodeRejectsNilOrEmptyDeviceId() {
        let detection = QueuedDetection(
            uuid: fleetUUID,
            major: 1,
            minor: 1,
            bestRSSI: -60,
            latestTimestamp: timestamp,
            windowStartedAt: timestamp,
            observationCount: 1,
            location: nil,
            queuedAt: timestamp
        )
        let encoder = BeaconUploadPayloadEncoder()

        XCTAssertThrowsError(try encoder.encode([detection], deviceId: nil)) { error in
            XCTAssertTrue(error is BeaconUploadPayloadEncoder.MissingDeviceIdentifier)
        }
        XCTAssertThrowsError(try encoder.encode([detection], deviceId: "")) { error in
            XCTAssertTrue(error is BeaconUploadPayloadEncoder.MissingDeviceIdentifier)
        }
    }

    func testDocumentMapsFromQueuedDetection() {
        let detection = QueuedDetection(
            uuid: fleetUUID,
            major: 1,
            minor: 9,
            bestRSSI: -62,
            latestTimestamp: timestamp,
            windowStartedAt: timestamp,
            observationCount: 2,
            location: nil,
            queuedAt: timestamp
        )
        let document = BeaconUploadPayloadEncoder().document(
            from: [detection],
            deviceId: deviceId
        )
        XCTAssertEqual(document.detections.count, 1)
        XCTAssertEqual(document.detections[0].uuid, fleetUUID)
        XCTAssertEqual(document.detections[0].bestRssiDbm, -62)
        XCTAssertEqual(document.detections[0].firstSeen, timestamp)
        XCTAssertEqual(document.detections[0].lastSeen, timestamp)
        XCTAssertEqual(document.detections[0].observations, 2)
        XCTAssertEqual(document.detections[0].deviceId, deviceId)
        XCTAssertEqual(document.detections[0].idempotencyKey, detection.id.uuidString)
        XCTAssertNil(document.detections[0].lat)
        XCTAssertNil(document.detections[0].lng)
    }

    func testIdempotencyKeyStableAcrossReencodesAndDistinctAcrossRecords() throws {
        let first = QueuedDetection(
            uuid: fleetUUID,
            major: 1,
            minor: 1,
            bestRSSI: -50,
            latestTimestamp: timestamp,
            windowStartedAt: timestamp,
            observationCount: 1,
            location: nil,
            queuedAt: timestamp
        )
        let second = QueuedDetection(
            uuid: fleetUUID,
            major: 1,
            minor: 2,
            bestRSSI: -50,
            latestTimestamp: timestamp,
            windowStartedAt: timestamp,
            observationCount: 1,
            location: nil,
            queuedAt: timestamp
        )
        let encoder = BeaconUploadPayloadEncoder()
        let firstA = encoder.document(from: [first], deviceId: deviceId)
        let firstB = encoder.document(from: [first], deviceId: deviceId)
        let secondDoc = encoder.document(from: [second], deviceId: deviceId)
        XCTAssertEqual(
            firstA.detections[0].idempotencyKey,
            firstB.detections[0].idempotencyKey
        )
        XCTAssertEqual(firstA.detections[0].idempotencyKey, first.id.uuidString)
        XCTAssertNotEqual(
            firstA.detections[0].idempotencyKey,
            secondDoc.detections[0].idempotencyKey
        )
    }
}
