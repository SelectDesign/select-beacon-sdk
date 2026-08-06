import XCTest
@testable import SelectBeaconSDK

final class UploadAuthenticationTests: XCTestCase {
    func testAuthIsPausedByDefault() {
        XCTAssertFalse(
            UploadAuthentication.isEnabled,
            "Flip UploadAuthentication.isEnabled to true when the token broker is ready"
        )
    }

    @MainActor
    func testPausedAuthProviderReturnsEmptyTokenWithoutNetwork() async throws {
        let token = try await PausedAuthProvider().validToken()
        XCTAssertEqual(token, "")
    }
}
