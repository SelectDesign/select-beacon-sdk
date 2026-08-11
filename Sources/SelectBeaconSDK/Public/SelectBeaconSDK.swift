import Foundation

/// Thin public shell for the detection-stack PR. Full facade lands in a follow-up PR.
@MainActor
public final class SelectBeaconSDK {
    public static let shared = SelectBeaconSDK()

    public private(set) var operationalStatus: SDKOperationalStatus = .unconfigured

    private init() {}

    public static func configure(
        appKey: String,
        appSecret: String,
        environment: Environment = .production
    ) {
        guard let identity = AppIdentity(appKey: appKey, appSecret: appSecret) else {
            shared.operationalStatus = .degraded(.invalidConfiguration)
            return
        }
        shared.configure(identity: identity, environment: environment)
    }

    func configure(identity: AppIdentity, environment: Environment) {
        guard SDKEnablementConfiguration(identity: identity, environment: environment) != nil else {
            operationalStatus = .degraded(.invalidConfiguration)
            return
        }
        operationalStatus = .ready
    }
}
