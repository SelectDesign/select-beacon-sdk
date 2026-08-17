import CoreLocation
import Foundation
@testable import SelectBeaconSDK

@MainActor
final class FakeEngine: DetectionEngine {
    var onBeacons: (([DetectedBeacon]) -> Void)?
    private(set) var startedUUIDs: [[UUID]] = []
    private(set) var stopCount = 0
    private(set) var applicationActiveValues: [Bool] = []

    func start(uuids: [UUID]) {
        startedUUIDs.append(uuids)
    }

    func stop() {
        stopCount += 1
    }

    func setApplicationActive(_ isActive: Bool) {
        applicationActiveValues.append(isActive)
    }

    func emit(_ beacons: [DetectedBeacon]) {
        onBeacons?(beacons)
    }
}

/// Fake `LocationManaging` for `CoreLocationDetectionEngine` / live-auth facade tests.
@MainActor
final class FakeBeaconLocationManager: LocationManaging {
    var delegate: CLLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    private(set) var startedConstraints: [CLBeaconIdentityConstraint] = []
    private(set) var stoppedConstraints: [CLBeaconIdentityConstraint] = []
    private(set) var startedRegions: [CLRegion] = []
    private(set) var stoppedRegions: [CLRegion] = []
    private(set) var requestedStateRegions: [CLRegion] = []

    func setAuthorization(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        (delegate as? CoreLocationDetectionEngine)?
            .locationManagerDidChangeAuthorization(CLLocationManager())
    }

    func clearRangingLog() {
        startedConstraints = []
        stoppedConstraints = []
    }

    func startRangingBeacons(satisfying constraint: CLBeaconIdentityConstraint) {
        startedConstraints.append(constraint)
    }

    func stopRangingBeacons(satisfying constraint: CLBeaconIdentityConstraint) {
        stoppedConstraints.append(constraint)
    }

    func startMonitoring(for region: CLRegion) {
        startedRegions.append(region)
    }

    func stopMonitoring(for region: CLRegion) {
        stoppedRegions.append(region)
    }

    func requestState(for region: CLRegion) {
        requestedStateRegions.append(region)
    }

    var monitoredBeaconUUIDs: [UUID] {
        startedRegions.compactMap { ($0 as? CLBeaconRegion)?.uuid }
    }
}

