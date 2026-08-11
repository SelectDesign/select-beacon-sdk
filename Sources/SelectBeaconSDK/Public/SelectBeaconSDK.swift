import Foundation

/// Thin public shell for the detection-stack PR. Full facade lands in a follow-up PR.
@MainActor
public final class SelectBeaconSDK {
    public static let shared = SelectBeaconSDK()

    public private(set) var operationalStatus: SDKOperationalStatus = .unconfigured

    private init() {}

    /// Enables the SDK. Safe to call from any thread; work runs on the main actor.
    ///
    /// The type remains `@MainActor`, but this entry point is `nonisolated` so
    /// hosts are not forced onto the main actor at the call site.
    nonisolated public static func configure(
        appKey: String,
        appSecret: String,
        environment: Environment = .production
    ) {
        let apply: @MainActor () -> Void = {
            guard let identity = AppIdentity(appKey: appKey, appSecret: appSecret) else {
                shared.operationalStatus = .degraded(.invalidConfiguration)
                return
            }
            shared.configure(identity: identity, environment: environment)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(apply)
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated(apply)
            }
        }
    }

    func configure(identity: AppIdentity, environment: Environment) {
        guard SDKEnablementConfiguration(identity: identity, environment: environment) != nil else {
            operationalStatus = .degraded(.invalidConfiguration)
            return
        }
        operationalStatus = .ready
    }
}
