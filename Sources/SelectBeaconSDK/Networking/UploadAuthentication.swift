import Foundation

/// Temporary control for ingest authentication.
///
/// Auth is **paused** by default: live uploads use `PausedAuthProvider` (no
/// token-broker network call) and omit the `Authorization` header. Set
/// `isEnabled` to `true` when the broker is ready so `TokenBrokerAuthProvider`
/// and the 401 refresh path run again.
enum UploadAuthentication {
    /// When `false`, live wiring skips the token broker and omits Bearer auth.
    /// `nonisolated(unsafe)` is intentional for this temporary kill-switch;
    /// flip only from tests or a deliberate one-line re-enable.
    nonisolated(unsafe) static var isEnabled = false
}

/// No-op auth used while `UploadAuthentication.isEnabled` is `false`.
@MainActor
struct PausedAuthProvider: AuthProvider {
    func validToken() async throws -> String {
        ""
    }
}
