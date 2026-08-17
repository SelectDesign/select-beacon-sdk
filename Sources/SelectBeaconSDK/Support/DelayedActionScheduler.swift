import Foundation

/// Schedules one delayed action; a newer schedule replaces the previous one.
@MainActor
protocol DelayedActionScheduling: AnyObject {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class TaskDelayedActionScheduler: DelayedActionScheduling {
    private var task: Task<Void, Never>?

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor [weak self] in
            do {
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
