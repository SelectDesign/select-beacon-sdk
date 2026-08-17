import Foundation

/// A small value-type cache of the beacons recently seen by Core Location.
///
/// This is intentionally not an `actor`: `SelectBeaconSDK` owns it on the main
/// actor, so access is already serialized. Keeping it separate from
/// `ObservationWindowStore` prevents report aggregation from changing the
/// answer to the different question, "which beacons are currently nearby?"
struct ActiveBeaconStore {
    private var observations: [BeaconIdentity: BeaconObservation] = [:]

    /// The adapter receives stable ordering even though Swift dictionaries do
    /// not promise iteration order. Stable ordering avoids UI lists appearing
    /// to reshuffle when only RSSI changes.
    var snapshot: [BeaconObservation] {
        observations.values.sorted {
            if $0.uuid != $1.uuid {
                return $0.uuid.uuidString < $1.uuid.uuidString
            }
            if $0.major != $1.major {
                return $0.major < $1.major
            }
            return $0.minor < $1.minor
        }
    }

    /// The oldest last-seen timestamp determines the next time any entry can
    /// expire. The caller adds the configured absence timeout.
    var nextExpiry: Date? {
        observations.values.map(\.observedAt).min()
    }

    /// Upserts by fleet UUID, major, and minor. A new RSSI replaces the previous
    /// value because this view represents the latest observation, not an average.
    mutating func record(_ observation: BeaconObservation) {
        observations[
            BeaconIdentity(
                uuid: observation.uuid,
                major: observation.major,
                minor: observation.minor
            )
        ] = observation
    }

    /// Drops beacons whose last observation is at or before the cutoff.
    ///
    /// Returning a Boolean lets the caller avoid publishing a redundant
    /// unchanged snapshot to the app.
    mutating func expire(before cutoff: Date) -> Bool {
        let previousCount = observations.count
        observations = observations.filter { $0.value.observedAt > cutoff }
        return observations.count != previousCount
    }

    /// Ends the current presence view without touching the durable report queue.
    mutating func clear() -> Bool {
        guard !observations.isEmpty else { return false }
        observations.removeAll()
        return true
    }
}
