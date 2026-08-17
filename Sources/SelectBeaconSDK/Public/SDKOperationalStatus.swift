/// The non-sensitive operating state of the SDK.
public enum SDKOperationalStatus: Equatable, Sendable {
    /// `configure(appKey:appSecret:)` has not completed successfully.
    case unconfigured

    /// The SDK is configured but detection has not been requested.
    case ready

    /// Detection was requested and the SDK is waiting for location authorization.
    case awaitingPermission

    /// Detection was requested but cannot run while the application is inactive.
    case paused

    /// Core Location ranging is active.
    case ranging

    /// A recoverable SDK issue requires host attention.
    case degraded(SDKOperationalIssue)
}

/// A non-sensitive issue reported by the SDK.
public enum SDKOperationalIssue: Equatable, Sendable {
    case invalidConfiguration
    case configurationLocked
    case startRequestedBeforeConfiguration
    case locationPermissionUnavailable
    case durableQueueWriteFailed
    case durableQueueUnreadable
    /// Token-broker / auth mint failed (bad credentials, suspension, or unusable auth config).
    ///
    /// Detection may continue and Queued reports are retained. Upload keeps
    /// retrying with backoff. Clears on the next successful token mint or a
    /// successful `configure` (same or new appKey/secret).
    case authenticationFailed
}

/// Why `selectClearPendingReports()` / `selectClearDeadLetteredReports()` refused or could not run.
@_spi(SelectApp)
public enum SelectPendingReportsClearError: Error, Equatable, Sendable {
    case notConfigured
    case detectionActive
    case stopFinalizePending
}
