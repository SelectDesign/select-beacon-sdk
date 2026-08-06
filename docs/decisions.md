# Architecture decisions

## Detection and identity

- Use Core Location iBeacon **region monitoring** (wake) plus **ranging**
  (major/minor/RSSI). No raw Bluetooth / CoreBluetooth scanning.
- Ship one fleet UUID: `76F87C5C-AB0C-45C5-8E9A-19DEF7DC2911`.
  Collection-shaped internal storage leaves room for future fleet expansion
  (soft-capped so the SDK does not exhaust the app-wide 20-region budget shared
  with the host).
- Background beacon wakes require host location background capability
  (`UIBackgroundModes`); the SDK implements monitoring/ranging only.
- Major identifies the program (Pernod = 1); Minor identifies the unit.
- The backend resolves serials. The SDK reports UUID, Major, and Minor only.

## Public API and enablement

- Standard consumers receive `SelectBeaconSDK.configure(appKey:)`,
  `shared.start()`, `shared.stop()`, and non-sensitive `operationalStatus`.
- `SelectBeaconAppSupport` is a separate Select-owned product exposing active,
  open-window, pending-report, and dead-lettered-report snapshots through a
  core SPI bridge. The SPI is an organizational boundary, not security
  enforcement. Active beacons are ordered by UUID → major → minor. Dead letters
  use the same report model as pending but stay in a separate list and are not
  re-uploaded; `clearPendingReports()` does not clear them.
- The host supplies an app key before detection can start. Configuration stores
  it only; configure never starts ranging, reads disk, or uses the network.
- Production is the default (`REPLACE_ME_PRODUCTION` until its host is
  confirmed). Staging requires a caller-supplied URL. Environment cannot change
  after `start()`.

## Permission, lifecycle, and concurrency

- Observe host-owned location authorization; never request permission.
- Always authorization keeps the engine started when backgrounded: region
  monitoring can wake the app (host location background mode required); ranging
  runs on enter/inside bursts, not continuous background ranging. When-In-Use
  detects only while the app is active.
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

- Transmission is **store-and-forward**: finalize → durable local queue
  immediately; drain to the API in batches on the earliest connectivity-gated
  opportunity. Never per-event HTTP; never block capture on the network. Chosen
  for battery-friendly batching, offline retention, background resilience, and
  at-least-once eventual delivery in a crowdsourced / delay-tolerant setting
  (see `architecture.md` §5b).
- **Auth is temporarily paused** (`UploadAuthentication.isEnabled == false`):
  ingest POSTs without calling the token broker and without an `Authorization`
  header. Re-enable by setting that flag to `true` when the broker is ready;
  `TokenBrokerAuthProvider` and the 401 refresh path remain in place.
- Forward triggers: foreground sighting quiet (60s), maximum queue age (300s),
  app background/foreground, connectivity return, cold-start backlog flush, or
  post-enqueue opportunistic flush when online. **Background wake / background
  sighting flushes are bounded to one batch** so the wake window stays short;
  remaining records stay durable until a later full-drain trigger.
- Offline means retain without an attempt or backoff. Retryable failures back off
  15s, doubling to 300s, and reset after successful acknowledgement.
  `Retry-After` (including header-less 429 → exponential) is honored for rate
  limits. 401/403 invalidates the token, refreshes once, and retries immediately.
  Other 4xx dead-letter the batch; retryable failures dead-letter after
  `maxUploadAttempts`. Pending queue size/age caps apply with eviction diagnostics.
- Auth is `POST {base}/ingest/auth/v1` with `app_key`; responses use
  `access_token` and `expires_in`.
- Ingest is `POST {base}/ingest/sdk/v1/detections` with body
  `{ "detections": [ { "uuid": …, "best_rssi_dbm": …, … } ] }`,
  snake_case fields (including stable `idempotency_key`), and Bearer
  authorization. HTTP 200 acknowledges the posted batch. Backend must dedupe on
  `idempotency_key` for at-least-once re-sends.
- The SDK obtains short-lived tokens using `appKey` only. It never holds or
  transmits an app secret or Auth0 client secret.
- The production host remains `REPLACE_ME_PRODUCTION` until replaced; explicit
  usable staging URLs use the live auth and HTTP implementations.
