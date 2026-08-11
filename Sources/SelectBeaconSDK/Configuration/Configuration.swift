/// Shared HTTPS endpoint validation for staging, auth, and ingest URLs.
///
/// Cleartext `http` is rejected package-wide.

import Foundation
import CryptoKit
import CoreLocation

extension URL {
    /// Absolute `https` URL with a non-nil host (cleartext `http` rejected).
    var isUsableHTTPSEndpoint: Bool {
        scheme?.lowercased() == "https" && host != nil
    }
}

/// Tunable detection, observation-window, upload, and location defaults.
struct SDKConfiguration {
    let monitoredUUIDs: [UUID]

    /// Length of each observation window that aggregates sightings into one report.
    let windowDuration: TimeInterval

    /// Close an open observation window when a beacon has not been seen for this long.
    let absenceTimeout: TimeInterval

    /// Foreground quiet period with no beacon sightings before a batch upload attempt.
    let sendDebounce: TimeInterval

    /// Force a send when the oldest queued report has waited longer than this,
    /// even if beacon activity never goes quiet.
    let maxQueueAge: TimeInterval

    /// Maximum reports included in one upload batch.
    let uploadBatchLimit: Int

    /// Initial retry delay after a failed upload attempt.
    let uploadRetryBackoff: TimeInterval

    /// Upper bound for exponential upload retry backoff.
    let uploadRetryBackoffMax: TimeInterval

    /// Retryable upload failures for a record before it is moved to the dead-letter store.
    let maxUploadAttempts: Int

    /// Maximum pending detections retained in the durable FIFO queue.
    let maxQueueSize: Int

    /// Drop pending detections whose `queuedAt` is older than this age.
    let maxRecordAge: TimeInterval

    /// Coarse accuracy for standard location updates while detecting ("which store/area").
    /// Uses hundred-meter class accuracy instead of Best to limit battery use.
    let locationAccuracy: CLLocationAccuracy

    /// Minimum movement before Core Location delivers another coarse update.
    let locationDistanceFilterMeters: CLLocationDistance

    /// When true and authorization is Always, significant-change monitoring keeps
    /// a roughly current cache between ranging windows.
    let useSignificantChangeBaseline: Bool

    static let `default` = SDKConfiguration(
        monitoredUUIDs: [selectFleetUUID],
        windowDuration: 60,
        absenceTimeout: 30,
        sendDebounce: 60,
        maxQueueAge: 300,
        uploadBatchLimit: 50,
        uploadRetryBackoff: 15,
        uploadRetryBackoffMax: 300,
        maxUploadAttempts: 8,
        maxQueueSize: 500,
        maxRecordAge: 604_800,
        locationAccuracy: kCLLocationAccuracyHundredMeters,
        locationDistanceFilterMeters: 100,
        useSignificantChangeBaseline: true
    )

    /// Returns a copy with selected knobs overridden (tests and local wiring).
    func with(
        uploadBatchLimit: Int? = nil,
        maxUploadAttempts: Int? = nil,
        useSignificantChangeBaseline: Bool? = nil
    ) -> SDKConfiguration {
        SDKConfiguration(
            monitoredUUIDs: monitoredUUIDs,
            windowDuration: windowDuration,
            absenceTimeout: absenceTimeout,
            sendDebounce: sendDebounce,
            maxQueueAge: maxQueueAge,
            uploadBatchLimit: uploadBatchLimit ?? self.uploadBatchLimit,
            uploadRetryBackoff: uploadRetryBackoff,
            uploadRetryBackoffMax: uploadRetryBackoffMax,
            maxUploadAttempts: maxUploadAttempts ?? self.maxUploadAttempts,
            maxQueueSize: maxQueueSize,
            maxRecordAge: maxRecordAge,
            locationAccuracy: locationAccuracy,
            locationDistanceFilterMeters: locationDistanceFilterMeters,
            useSignificantChangeBaseline: useSignificantChangeBaseline
                ?? self.useSignificantChangeBaseline
        )
    }

    private static let selectFleetUUID = UUID(
        uuid: (
            0x76, 0xF8, 0x7C, 0x5C,
            0xAB, 0x0C,
            0x45, 0xC5,
            0x8E, 0x9A,
            0x19, 0xDE, 0xF7, 0xDC, 0x29, 0x11
        )
    )
}

struct AppIdentity: Equatable {
    let appKey: String
    let appSecret: String

    init?(appKey: String, appSecret: String) {
        let trimmedKey = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedSecret.isEmpty else {
            return nil
        }
        self.appKey = trimmedKey
        self.appSecret = trimmedSecret
    }
}

struct APIEndpoint: Equatable {
    let baseURL: String

    /// `POST` target for short-lived upload tokens.
    var authURL: URL? {
        url(path: "/auth/v1")
    }

    /// `POST` target for beacon ingest.
    var ingestURL: URL? {
        url(path: "/sdk/v1/detections")
    }

    /// True when `baseURL` is a usable HTTPS absolute URL (not the production placeholder).
    var isUsableHTTPBase: Bool {
        authURL != nil && ingestURL != nil
    }

    private func url(path: String) -> URL? {
        var trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty,
              trimmedBase != APIEndpointDefaults.production else {
            return nil
        }
        while trimmedBase.hasSuffix("/") {
            trimmedBase.removeLast()
        }

        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: trimmedBase + suffix),
              url.isUsableHTTPSEndpoint else {
            return nil
        }
        return url
    }
}

/// Configuration supplied internally to the SDK's token-broker auth provider.
///
/// The provider posts `app_key` and `app_secret` to this endpoint. The secret
/// is held in memory only for broker exchange — never logged or written to the
/// durable queue. No Auth0 client secret is used.
struct TokenBrokerConfiguration: Equatable {
    let appKey: String
    let appSecret: String
    let tokenEndpoint: URL

    init?(appKey: String, appSecret: String, tokenEndpoint: URL) {
        let trimmedAppKey = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAppSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAppKey.isEmpty, !trimmedAppSecret.isEmpty else {
            return nil
        }

        self.appKey = trimmedAppKey
        self.appSecret = trimmedAppSecret
        self.tokenEndpoint = tokenEndpoint
    }

    init?(identity: AppIdentity, tokenEndpoint: URL) {
        self.init(
            appKey: identity.appKey,
            appSecret: identity.appSecret,
            tokenEndpoint: tokenEndpoint
        )
    }
}

extension SelectBeaconSDK {
    /// Selects the API environment used by the upload pipeline.
    public enum Environment: Equatable, Sendable {
        /// The default environment used by production app integrations.
        case production

        /// A caller-supplied staging endpoint, allowing multiple staging deployments.
        /// Must be an absolute `https` URL with a host; cleartext `http` is rejected.
        case staging(baseURL: URL)

        fileprivate var endpoint: APIEndpoint? {
            switch self {
            case .production:
                return APIEndpoint(baseURL: APIEndpointDefaults.production)
            case .staging(let baseURL):
                guard baseURL.isUsableHTTPSEndpoint else {
                    return nil
                }
                return APIEndpoint(baseURL: baseURL.absoluteString)
            }
        }
    }
}

enum APIEndpointDefaults {
    static let production = "REPLACE_ME_PRODUCTION"
}

struct SDKEnablementConfiguration: Equatable {
    let identity: AppIdentity
    let environment: SelectBeaconSDK.Environment
    let endpoint: APIEndpoint

    init?(identity: AppIdentity, environment: SelectBeaconSDK.Environment) {
        guard let endpoint = environment.endpoint else {
            return nil
        }
        self.identity = identity
        self.environment = environment
        self.endpoint = endpoint
    }

    /// Keeps durable records isolated without writing the app key or secret
    /// into the file path.
    var queueStorageIdentifier: String {
        let namespace = "\(identity.appKey)|\(endpoint.baseURL)"
        return SHA256.hash(data: Data(namespace.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func tokenBrokerConfiguration() -> TokenBrokerConfiguration? {
        guard let tokenEndpoint = endpoint.authURL else {
            return nil
        }
        return TokenBrokerConfiguration(
            identity: identity,
            tokenEndpoint: tokenEndpoint
        )
    }
}
