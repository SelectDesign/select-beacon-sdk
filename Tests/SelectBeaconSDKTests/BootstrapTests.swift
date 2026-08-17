import XCTest
@testable import SelectBeaconSDK

final class BootstrapTests: XCTestCase {
    /// Compile-/link-time guard for the docs/CI placeholder symbol.
    ///
    /// Asserts the reflected type name so the test fails if the symbol is
    /// renamed without updating this suite (a bare `XCTAssertNotNil(T.self)`
    /// would never fail because metatypes are non-optional).
    func testBootstrapModuleExportsPlaceholderSymbol() {
        let typeName = String(reflecting: SelectBeaconSDKBootstrap.self)
        XCTAssertTrue(
            typeName.hasSuffix("SelectBeaconSDKBootstrap"),
            "Expected SelectBeaconSDKBootstrap, got \(typeName)"
        )
    }
}
