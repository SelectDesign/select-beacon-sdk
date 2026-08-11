/// Pure SDK coordination state for enablement, authorization, and lifecycle.
struct RangingSessionState: Equatable {
    enum Effect: Equatable {
        case none
        case startRanging
        case stopRanging
    }

    private(set) var isConfigured = false
    private(set) var wantsRanging = false
    private(set) var authorization: LocationAuthorization = .notDetermined
    private(set) var isApplicationActive = false
    private(set) var isRanging = false

    mutating func configure() {
        isConfigured = true
    }

    mutating func startRequested() -> Effect {
        wantsRanging = true
        return reconcile()
    }

    mutating func stopRequested() -> Effect {
        wantsRanging = false
        return reconcile()
    }

    mutating func authorizationChanged(_ authorization: LocationAuthorization) -> Effect {
        self.authorization = authorization
        return reconcile()
    }

    mutating func applicationActivityChanged(_ isActive: Bool) -> Effect {
        isApplicationActive = isActive
        return reconcile()
    }

    mutating func didStartRanging() {
        isRanging = true
    }

    mutating func didStopRanging() {
        isRanging = false
    }

    private mutating func reconcile() -> Effect {
        let shouldRange: Bool
        switch authorization {
        case .always:
            shouldRange = isConfigured && wantsRanging
        case .whenInUse:
            shouldRange = isConfigured && wantsRanging && isApplicationActive
        case .notDetermined, .unavailable:
            shouldRange = false
        }

        if shouldRange && !isRanging {
            return .startRanging
        }
        if !shouldRange && isRanging {
            return .stopRanging
        }
        return .none
    }
}
