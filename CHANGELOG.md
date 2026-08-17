# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-08-17

First tagged Swift package drop for host apps and the Select-owned app.

### Added

#### Package

- iOS 17+, Swift 6, no third-party dependencies.
- Proprietary license (see `LICENSE`); use and integration are governed by
  a separate written agreement with Select.
- SPM products `SelectBeaconSDK` (standard hosts) and `SelectBeaconAppSupport`
  (Select-owned UI).
- `PrivacyInfo.xcprivacy` declaring Device ID (IDFV) and Precise Location for
  App Functionality with tracking disabled. Host Info.plist usage strings
  remain host-owned.

#### Standard host API (`SelectBeaconSDK`)

- `configure(appKey:appSecret:environment:)` before `start()`. Production is
  the default; staging requires a caller-supplied **HTTPS** URL (cleartext
  `http` is rejected). Configure stores credentials in memory only — it does
  not range, touch disk, or use the network.
- `configure` is `nonisolated`: on the main thread enablement applies before
  return; off the main thread credentials are FIFO-staged and applied on the
  main actor (never `DispatchQueue.main.sync`). `start()` on `shared` drains
  any remaining stage before ranging.
- `shared.start()` / `shared.stop()`, `operationalStatus`, and
  `onOperationalStatusChanged`.
- Status: `unconfigured`, `ready`, `awaitingPermission`, `paused`, `ranging`,
  and `degraded` for `invalidConfiguration`, `configurationLocked`,
  `startRequestedBeforeConfiguration`, `locationPermissionUnavailable`,
  `durableQueueWriteFailed`, `durableQueueUnreadable`, and
  `authenticationFailed`.
- Optional `setDiagnosticsReporter` / `SelectBeaconDiagnosticsReporting` for
  coarse events (queue, upload, dead-letter, eviction, missing device id).
  Never log tokens, secrets, or full payloads.

#### Detection

- Core Location iBeacon region monitoring and ranging. No CoreBluetooth
  scanning. Single fleet UUID `76F87C5C-AB0C-45C5-8E9A-19DEF7DC2911`.
- Identify beacons by UUID / major / minor only (no serial resolution in the
  SDK).
- Observe host-owned location authorization; never request permission.
  Always plus location background mode enables region-wake ranging bursts.
  When-In-Use detects only while the app is active.
- 60-second observation windows (`bestRSSI`, latest non-nil cached location,
  `latestTimestamp`, `observationCount`). Close on window end or 30-second
  absence and enqueue immediately. `stop()` finalizes all open windows.
- Cached location only; no one-shot GPS per sighting.

#### Durable queue and upload

- Actor-isolated file-backed pending queue and dead-letter store. Files and
  their Application Support directory use Data Protection
  `completeUntilFirstUserAuthentication`. Pending→dead-letter moves persist
  the dead-letter file first; reload reconciles duplicate IDs.
- Store-and-forward: enqueue immediately, drain later. Triggers: quiet
  debounce (foreground), max queue age, lifecycle, connectivity return,
  cold-start backlog, and opportunistic flush when online. Background region
  wakes attempt one batch only.
- Live token broker `POST {base}/auth/v1` (`app_key` / `app_secret`) and
  ingest `POST {base}/sdk/v1/detections` with `Authorization`, snake_case JSON
  (including stable `idempotency_key`). Production host
  `https://ingestor.beacons.selectbrandhub.com`.
- Host-visible token-broker failures surface as
  `.degraded(.authenticationFailed)` while upload retries with backoff.
  Broker auth failures do not increment `uploadAttemptCount`. Ingest 401/403
  invalidates the token, refreshes once, and retries immediately. Other 4xx
  dead-letter the batch; ingest/network retryable failures dead-letter after
  `maxUploadAttempts`.
- Only `stop()` advances `deliverySession`. Pending/dead-letter clears wait
  for scheduled durable delivery and in-flight upload flush so a late enqueue
  or dead-letter cannot repopulate after success.

#### Select app (`SelectBeaconAppSupport`)

- Snapshots and change callbacks: active beacons, open windows, pending
  reports, dead-lettered reports, and `isStopFinalizePending`.
- `clearPendingReports()` / `clearDeadLetteredReports()` while detection is
  stopped and stop-finalize has settled. The two stores are independent.
- Gate Start on `isStopFinalizePending`, not an empty open-window snapshot.
- Standard hosts must not depend on `SelectBeaconAppSupport` or import
  `@_spi(SelectApp)`.

#### Documentation

- Host and Select integration guides, architecture, decisions,
  development-context, release runbook, and BeaconTest harness under
  `Examples/BeaconTest`.

### Known limitations

- Host and Select app keys/secrets still need provisioning against the token
  broker for each install.
- Background `URLSession` (Tier B) is intentionally out of scope: confirmed
  location-wake piggybacking; the SDK uses bounded wake flushes only.
- The iOS Simulator cannot validate iBeacon ranging. Physical-device smoke
  tests remain a [release-runbook](docs/releasing.md) gate and are not claimed
  by this tag.
