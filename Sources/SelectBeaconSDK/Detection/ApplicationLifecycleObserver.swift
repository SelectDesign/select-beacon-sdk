import UIKit

/// Owns NotificationCenter tokens outside the main actor.
///
/// NotificationCenter tokens are Objective-C objects and are not `Sendable`
/// under Swift's strict-concurrency rules. This small wrapper removes them in
/// `deinit`; `@unchecked Sendable` is safe here because the tokens are created
/// once, never mutated, and only used for observer removal.
private final class NotificationObserverRegistration: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let tokens: [NSObjectProtocol]

    init(notificationCenter: NotificationCenter, tokens: [NSObjectProtocol]) {
        self.notificationCenter = notificationCenter
        self.tokens = tokens
    }

    deinit {
        tokens.forEach { notificationCenter.removeObserver($0) }
    }
}

@MainActor
protocol ApplicationLifecycleObserving: AnyObject {
    var isActive: Bool { get }
    var onActivityChanged: ((Bool) -> Void)? { get set }
}

/// Keeps When-In-Use ranging in the foreground without altering host lifecycle behavior.
///
/// The SDK observes UIKit notifications but never changes application state,
/// starts a background task, or requests additional permission. The callback
/// only tells `RangingSessionState` whether foreground-only ranging is allowed.
@MainActor
final class ApplicationLifecycleObserver: ApplicationLifecycleObserving {
    var onActivityChanged: ((Bool) -> Void)?

    private var observerRegistration: NotificationObserverRegistration?
    private(set) var isActive: Bool

    init(notificationCenter: NotificationCenter = .default) {
        isActive = UIApplication.shared.applicationState == .active

        // NotificationCenter invokes these closures outside this class's actor
        // isolation. Hop back to the main actor before mutating `isActive` or
        // calling the SDK callback.
        let observerTokens = [
            notificationCenter.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setActive(true)
                }
            },
            notificationCenter.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setActive(false)
                }
            },
        ]
        observerRegistration = NotificationObserverRegistration(
            notificationCenter: notificationCenter,
            tokens: observerTokens
        )
    }

    private func setActive(_ isActive: Bool) {
        guard self.isActive != isActive else { return }
        self.isActive = isActive
        onActivityChanged?(isActive)
    }
}
