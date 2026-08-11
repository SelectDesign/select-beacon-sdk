import Foundation
@testable import SelectBeaconSDK

final class FakeDeviceIdentifier: DeviceIdentifying {
    var deviceId: String?

    init(deviceId: String? = "test-device-id") {
        self.deviceId = deviceId
    }
}
