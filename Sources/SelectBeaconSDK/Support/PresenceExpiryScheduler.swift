import Foundation

/// A replaceable one-shot timer used only for active-beacon expiry.
///
/// The protocol keeps timer behavior out of `SelectBeaconSDK`, letting tests
/// advance expiry explicitly instead of sleeping for real time. `@MainActor`
/// means both scheduling and the callback execute on the same serialized
/// executor as SDK state.
@MainActor
protocol PresenceExpiryScheduling: AnyObject {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class TaskPresenceExpiryScheduler: PresenceExpiryScheduling {
    private var task: Task<Void, Never>?

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        // There is only one relevant deadline: the next beacon expected to
        // expire. Replacing the prior task prevents timer accumulation as
        // ranging observations arrive.
        cancel()
        task = Task { @MainActor [weak self] in
            do {
                // `Task.sleep` throws only when cancellation interrupts the
                // wait; cancellation is normal whenever a newer deadline wins.
                try await Task.sleep(for: .seconds(Swift.max(0, delay)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.task = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
