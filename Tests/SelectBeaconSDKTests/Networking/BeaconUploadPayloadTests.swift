import XCTest
@_spi(SelectApp) @testable import SelectBeaconSDK

final class BeaconUploadPayloadTests: XCTestCase {
    private let fleetUUID = SDKConfiguration.default.monitoredUUIDs[0]
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    private let deviceId = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"

    func testEncodeDocumentUsesJSONAPIAndKebabCaseKeys() throws {
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
        let resources = try XCTUnwrap(json["data"] as? [[String: Any]])
        XCTAssertEqual(resources.count, 1)
        let resource = try XCTUnwrap(resources.first)
        XCTAssertEqual(resource["type"] as? String, "sdk_beacon")
        XCTAssertNil(resource["id"])
        let attributes = try XCTUnwrap(resource["attributes"] as? [String: Any])
        XCTAssertEqual(Set(attributes.keys), [
            "uuid", "major", "minor", "best-rssi-dbm", "observations",
            "lat", "lng", "first-seen", "last-seen", "device-id",
        ])
        XCTAssertEqual(attributes["uuid"] as? String, fleetUUID.uuidString)
        XCTAssertEqual(attributes["major"] as? Int, 1)
        XCTAssertEqual(attributes["minor"] as? Int, 42)
        XCTAssertEqual(attributes["best-rssi-dbm"] as? Int, -55)
        XCTAssertEqual(attributes["observations"] as? Int, 4)
        XCTAssertEqual(attributes["lat"] as? Double, 40.7128)
        XCTAssertEqual(attributes["lng"] as? Double, -74.006)
        XCTAssertEqual(attributes["device-id"] as? String, deviceId)
        XCTAssertEqual(attributes["first-seen"] as? String, "2023-11-14T22:12:50Z")
        XCTAssertEqual(attributes["last-seen"] as? String, "2023-11-14T22:13:20Z")
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
        let resources = try XCTUnwrap(json["data"] as? [[String: Any]])
        let attributes = try XCTUnwrap(resources.first?["attributes"] as? [String: Any])
        XCTAssertTrue(attributes["lat"] is NSNull)
        XCTAssertTrue(attributes["lng"] is NSNull)
        XCTAssertEqual(attributes["device-id"] as? String, deviceId)
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
        XCTAssertEqual(document.data.count, 1)
        XCTAssertEqual(document.data[0].type, "sdk_beacon")
        XCTAssertEqual(document.data[0].attributes.uuid, fleetUUID)
        XCTAssertEqual(document.data[0].attributes.bestRssiDbm, -62)
        XCTAssertEqual(document.data[0].attributes.firstSeen, timestamp)
        XCTAssertEqual(document.data[0].attributes.lastSeen, timestamp)
        XCTAssertEqual(document.data[0].attributes.observations, 2)
        XCTAssertEqual(document.data[0].attributes.deviceId, deviceId)
        XCTAssertNil(document.data[0].attributes.lat)
        XCTAssertNil(document.data[0].attributes.lng)
    }
}
