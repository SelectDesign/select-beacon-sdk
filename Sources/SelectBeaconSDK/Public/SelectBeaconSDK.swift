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
    ///
    /// On the main thread, enablement applies before `configure` returns. Off the
    /// main thread, credentials are staged under a lock and applied on the main
    /// actor shortly after return — never via `DispatchQueue.main.sync` (that
    /// deadlocks if main is waiting on the caller). Hosts that need `.ready`
    /// before the next statement should call `configure` on the main actor, or
    /// observe `operationalStatus` until enablement is visible.
    nonisolated public static func configure(
        appKey: String,
        appSecret: String,
        environment: Environment = .production
    ) {
        let staged: StagedEnablementBox.Kind
        if let identity = AppIdentity(appKey: appKey, appSecret: appSecret) {
            staged = .valid(identity: identity, environment: environment)
        } else {
            staged = .invalid
        }
        stagedEnablement.store(staged)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                shared.applyStagedEnablementIfNeeded()
            }
        } else {
            Task { @MainActor in
                shared.applyStagedEnablementIfNeeded()
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

    private func applyStagedEnablementIfNeeded() {
        let staged = stagedEnablement.takeAll()
        for item in staged {
            switch item {
            case .invalid:
                operationalStatus = .degraded(.invalidConfiguration)
            case .valid(let identity, let environment):
                configure(identity: identity, environment: environment)
            }
        }
    }
}

/// Lock-backed FIFO staging for `nonisolated` `configure` without `DispatchQueue.main.sync`.
private let stagedEnablement = StagedEnablementBox()

private final class StagedEnablementBox: @unchecked Sendable {
    enum Kind: Sendable {
        case valid(identity: AppIdentity, environment: SelectBeaconSDK.Environment)
        case invalid
    }

    private let lock = NSLock()
    private var queue: [Kind] = []

    func store(_ kind: Kind) {
        lock.lock()
        queue.append(kind)
        lock.unlock()
    }

    func takeAll() -> [Kind] {
        lock.lock()
        defer { lock.unlock() }
        let items = queue
        queue = []
        return items
    }
}
