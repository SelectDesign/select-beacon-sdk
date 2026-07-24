import Foundation
import UIKit

/// Supplies the install/device identifier stamped onto upload records as `deviceId`.
@MainActor
protocol DeviceIdentifying {
    /// `UIDevice.identifierForVendor` string, or nil when unavailable.
    var deviceId: String? { get }
}

/// Live IDFV reader used by production SDK dependencies.
@MainActor
struct VendorDeviceIdentifier: DeviceIdentifying {
    var deviceId: String? {
        UIDevice.current.identifierForVendor?.uuidString
    }
}
