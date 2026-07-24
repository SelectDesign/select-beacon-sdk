import Foundation

@_spi(SelectApp)
public struct DetectedBeacon {
    public let uuid: UUID
    public let major: Int
    public let minor: Int
    public let rssi: Int
}
