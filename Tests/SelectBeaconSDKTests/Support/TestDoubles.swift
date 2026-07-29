import Foundation
@testable import SelectBeaconSDK

@MainActor
final class FakeEngine: DetectionEngine {
    var onBeacons: (([DetectedBeacon]) -> Void)?
    private(set) var startedUUIDs: [[UUID]] = []
    private(set) var stopCount = 0

    func start(uuids: [UUID]) {
        startedUUIDs.append(uuids)
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ beacons: [DetectedBeacon]) {
        onBeacons?(beacons)
    }
}

@MainActor
final class FakePermissionObserver: PermissionObserver {
    var authorization: LocationAuthorization
    var onAuthorizationChanged: ((LocationAuthorization) -> Void)?

    init(authorization: LocationAuthorization = .always) {
        self.authorization = authorization
    }

    func setAuthorization(_ authorization: LocationAuthorization) {
        self.authorization = authorization
        onAuthorizationChanged?(authorization)
    }
}

@MainActor
final class FakeLifecycleObserver: ApplicationLifecycleObserving {
    var isActive: Bool
    var onActivityChanged: ((Bool) -> Void)?

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    func setActive(_ isActive: Bool) {
        self.isActive = isActive
        onActivityChanged?(isActive)
    }
}

@MainActor
final class InMemoryQueue: DurableDetectionQueue {
    private(set) var records: [QueuedDetection] = []

    func enqueue(_ detection: QueuedDetection) async throws {
        records.append(detection)
    }

    func nextBatch(limit: Int) async throws -> [QueuedDetection] {
        Array(records.prefix(limit))
    }

    func acknowledge(ids: [UUID]) async throws {
        let ids = Set(ids)
        records.removeAll { ids.contains($0.id) }
    }

    func clear() async throws {
        records.removeAll()
    }
}

@MainActor
final class FailingQueue: DurableDetectionQueue {
    struct WriteError: Error {}

    func enqueue(_ detection: QueuedDetection) async throws {
        throw WriteError()
    }

    func nextBatch(limit: Int) async throws -> [QueuedDetection] {
        []
    }

    func acknowledge(ids: [UUID]) async throws {}

    func clear() async throws {
        throw WriteError()
    }
}

@MainActor
final class UnreadableQueue: DurableDetectionQueue {
    private var cleared = false

    func enqueue(_ detection: QueuedDetection) async throws {
        guard !cleared else { return }
        throw DurableDetectionQueueError.unreadableStoredDetections
    }

    func nextBatch(limit: Int) async throws -> [QueuedDetection] {
        if cleared { return [] }
        throw DurableDetectionQueueError.unreadableStoredDetections
    }

    func acknowledge(ids: [UUID]) async throws {
        guard !cleared else { return }
        throw DurableDetectionQueueError.unreadableStoredDetections
    }

    func clear() async throws {
        cleared = true
    }
}

actor BlockingQueue: DurableDetectionQueue {
    private var records: [QueuedDetection] = []
    private var availableStarts = 0
    private var availableCompletions = 0
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var completionWaiter: CheckedContinuation<Void, Never>?
    private var writePermits: [CheckedContinuation<Void, Never>] = []

    func enqueue(_ detection: QueuedDetection) async throws {
        await withCheckedContinuation { permit in
            writePermits.append(permit)
            signalWriteStart()
        }
        records.append(detection)
        signalWriteCompletion()
    }

    func nextBatch(limit: Int) async throws -> [QueuedDetection] {
        Array(records.prefix(limit))
    }

    func acknowledge(ids: [UUID]) async throws {
        let ids = Set(ids)
        records.removeAll { ids.contains($0.id) }
    }

    func clear() async throws {
        records.removeAll()
    }

    func waitForWriteStart() async {
        if availableStarts > 0 {
            availableStarts -= 1
            return
        }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func releaseNextWrite() {
        writePermits.removeFirst().resume()
    }

    func waitForWriteCompletion() async {
        if availableCompletions > 0 {
            availableCompletions -= 1
            return
        }
        await withCheckedContinuation { completionWaiter = $0 }
    }

    private func signalWriteStart() {
        if let startWaiter {
            self.startWaiter = nil
            startWaiter.resume()
        } else {
            availableStarts += 1
        }
    }

    private func signalWriteCompletion() {
        if let completionWaiter {
            self.completionWaiter = nil
            completionWaiter.resume()
        } else {
            availableCompletions += 1
        }
    }
}

final class FakeDiagnosticsReporter: DiagnosticsReporting {
    private(set) var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent, error: Error) {
        events.append(event)
    }
}

struct FixedClock: Clock {
    let now: Date
}

final class MutableClock: Clock, @unchecked Sendable {
    var now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.now = now
    }
}

@MainActor
final class ManualDelayedActionScheduler: DelayedActionScheduling {
    private(set) var scheduledDelays: [TimeInterval] = []
    private var action: (@MainActor () -> Void)?

    var hasPendingAction: Bool { action != nil }

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        scheduledDelays.append(delay)
        self.action = action
    }

    func cancel() {
        action = nil
    }

    func fire() {
        let action = action
        self.action = nil
        action?()
    }
}

@MainActor
final class FakeLocationProvider: LocationProviding {
    var currentLocation: LocationFix?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isDetecting = false

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
        isDetecting = false
    }

    func setDetecting(_ isDetecting: Bool) {
        self.isDetecting = isDetecting
    }
}

@MainActor
final class FakeNetworkPathObserver: NetworkPathObserving {
    var isSatisfied: Bool
    var onPathChanged: ((Bool) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(isSatisfied: Bool = true) {
        self.isSatisfied = isSatisfied
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func setSatisfied(_ satisfied: Bool) {
        isSatisfied = satisfied
        onPathChanged?(satisfied)
    }
}
