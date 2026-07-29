# Architecture decisions

## Detection and identity

- Use Core Location iBeacon ranging only; no raw Bluetooth scanning.
- Ship one fleet UUID: `76F87C5C-AB0C-45C5-8E9A-19DEF7DC2911`.
  Collection-shaped internal storage leaves room for future fleet expansion.
- Major identifies the program (Pernod = 1); Minor identifies the unit.
- The backend resolves serials. The SDK reports UUID, Major, and Minor only.

## Public API and enablement

- Standard consumers receive `SelectBeaconSDK.configure(appKey:)`,
  `shared.start()`, `shared.stop()`, and non-sensitive `operationalStatus`.
- `SelectBeaconAppSupport` is a separate Select-owned product exposing active,
  open-window, and pending-report snapshots through a core SPI bridge. The SPI
  is an organizational boundary, not security enforcement.
- The host supplies an app key before detection can start. Configuration stores
  it only; configure never starts ranging, reads disk, or uses the network.
- Production is the default (`REPLACE_ME_PRODUCTION` until its host is
  confirmed). Staging requires a caller-supplied URL. Environment cannot change
  after `start()`.

## Permission, lifecycle, and concurrency

- Observe host-owned location authorization; never request permission.
- Always authorization may range in background. When-In-Use ranges only while
  the app is active.
- `SelectBeaconSDK` and Apple-system adapters are main-actor isolated.
- The package includes BeaconTest harness source for physical-device testing.

## Observation windows and location

- Aggregate sightings into 60-second windows using `bestRSSI`, latest non-nil
  cached location, `latestTimestamp`, and `observationCount`.
- Close on window expiry or 30-second absence and enqueue immediately.
  `stop()` finalizes all open windows.
- Use a low-power cached location provider: coarse updates while ranging and an
  optional significant-change baseline under Always authorization.
- Never request one-shot GPS per sighting. Unavailable authorization clears the
  cached fix to `nil`.

## Durable queue and delivery sessions

- File-backed storage is actor-isolated and asynchronous; disk I/O does not run
  on the SDK main actor.
- A serial delivery chain preserves queue order. Already-finalized reports
  finish durable persistence even if a later stop invalidates their callbacks.
- Only `stop()` advances `deliverySession`; `start()` does not. Session tokens
  suppress stale adapter notifications after asynchronous writes.
- Hosts gate Start on `SelectBeaconAppSupport.isStopFinalizePending`, not on an
  empty open-window snapshot. Repeated stop calls do not clear the flag before
  the full durable finalize batch settles.
- `clearPendingReports()` is available only while detection is stopped and
  stop-finalize has settled. Clearing intentionally overwrites corrupt payloads.
- Never overwrite unreadable pending detections during normal load/enqueue.
  Surface a typed queue-load error until storage is cleared.

## Upload and authentication

- Attempt batches on foreground sighting quiet (60s), maximum queue age (300s),
  app background/foreground, or connectivity return.
- Offline means retain without an attempt or backoff. Failed sends back off
  15s, doubling to 300s, and reset after successful acknowledgement.
- Background ranging wakes enqueue only.
- Auth is `POST {base}/ingest/auth/v1` with `app-key`; responses use
  `access-token` and `expires-in`.
- Ingest is JSON:API `POST {base}/ingest/sdk/v1`, resource type `sdk_beacon`,
  kebab-case attributes, and Bearer authorization. HTTP 200 acknowledges the
  posted batch.
- The SDK obtains short-lived tokens using `appKey` only. It never holds or
  transmits an app secret or Auth0 client secret.
- The production host remains `REPLACE_ME_PRODUCTION` until replaced; explicit
  usable staging URLs use the live auth and HTTP implementations.
