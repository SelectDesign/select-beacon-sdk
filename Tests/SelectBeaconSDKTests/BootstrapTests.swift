import XCTest
@testable import SelectBeaconSDK

final class BootstrapTests: XCTestCase {
    func testBootstrapSymbolExists() {
        XCTAssertNotNil(SelectBeaconSDKBootstrap.self)
    }
}
