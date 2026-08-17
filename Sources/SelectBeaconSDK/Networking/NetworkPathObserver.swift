import Foundation
import Network

/// Observes whether the device currently has a usable network path.
@MainActor
protocol NetworkPathObserving: AnyObject {
    var isSatisfied: Bool { get }
    var onPathChanged: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

/// Live path observer. Creates a fresh `NWPathMonitor` on each `start()` because
/// a cancelled monitor cannot be restarted.
@MainActor
final class NetworkPathObserver: NetworkPathObserving {
    var onPathChanged: ((Bool) -> Void)?
    private(set) var isSatisfied = true

    private var monitor: NWPathMonitor?
    private var generation = 0
    private let queue = DispatchQueue(label: "SelectBeaconSDK.NetworkPathObserver")

    func start() {
        guard monitor == nil else { return }
        generation &+= 1
        let generation = generation
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                let satisfied = path.status == .satisfied
                guard self.isSatisfied != satisfied else { return }
                self.isSatisfied = satisfied
                self.onPathChanged?(satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        generation &+= 1
        monitor?.cancel()
        monitor?.pathUpdateHandler = nil
        monitor = nil
    }
}
