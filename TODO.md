# SelectBeaconSDK — remaining work

Checklist for finishing the SDK and handing it to VIP as a consumable Swift
Package. Ordered roughly by dependency: production gates before a production
tag; packaging can proceed earlier with an explicit “staging uploads only”
limitation.

## Production gates (blocks production upload)

- [ ] Confirm and set the real production ingest host; replace
      `REPLACE_ME_PRODUCTION` in `APIEndpointDefaults` / configuration.
- [ ] Provision VIP (BizStride) and Select app keys/secrets against the token
      broker (`POST {base}/auth/v1`).
- [x] End-to-end staging upload: configure `.staging(baseURL:)` with
      `appKey`/`appSecret`, detect a real beacon, confirm flat JSON body lands
      in beacon-ingestor with Authorization, HTTP 200 clears the durable queue.
- [ ] End-to-end production upload after the host URL is set (same path,
      production key + secret + host).
- [x] Confirm with backend that wire attributes match ingest
      (`uuid`, `major`, `minor`, `best_rssi_dbm`, `observations`, `lat`/`lng`,
      `first_seen`, `last_seen`, `device_id`, `idempotency_key`; snake_case)
      and that whole-batch ack on HTTP 200 is final. Backend must dedupe on
      `idempotency_key` (at-least-once delivery).
- [x] Live ingest auth: `configure(appKey:appSecret:)` → `/auth/v1` →
      `Authorization` on detections (auth pause removed).
- [ ] VIP confirmation for background `URLSession` (Tier B) if system-completed
      uploads while suspended are required beyond opportunistic wake flushes.

## On-device validation (blocks a trustworthy VIP drop)

- [x] Physical iPhone smoke with `Examples/BeaconTest`: permission owned by
      host, in-range → open window → queued → upload/ack (staging or debug
      auto-ack).
- [x] Physical iPad smoke for the same flow.
- [ ] When-In-Use: ranging pauses in background and resumes in foreground.
- [ ] Always + location background mode: region-monitoring wakes start short
      ranging bursts; enqueue works; background flush is at most one batch.
- [ ] Relaunch with pending disk records still visible via
      `SelectBeaconAppSupport.pendingReports()`.
- [x] Staging vs production queue isolation (different `appKey` / base URL →
      separate storage namespaces).
- [ ] Stop-finalize: Start stays gated on `isStopFinalizePending` until durable
      enqueue settles.

## Package for VIP (distribution)

- [x] Agree the Git remote VIP will depend on (this repo or a VIP-visible
      mirror) and access (org, deploy key, or public).
- [x] Add `LICENSE` (MIT) before the first tagged release.
- [ ] Add `CHANGELOG.md` (or release notes template) starting at the first tag.
- [ ] Cut an annotated semver tag (`v0.x` if uploads are staging-only;
      `v1.0.0` only after production gates).
- [ ] Push the tag; give VIP the SPM URL + exact version/tag to pin.
- [ ] VIP BizStride integration notes (one page):
  - depend on product `SelectBeaconSDK` only
  - host Info.plist location usage strings; for background / screen-off wakes
    require **Always** authorization **and** location background mode
    (`UIBackgroundModes` / capability) — Always alone is not enough
  - `configure(appKey:appSecret:)` then `start()` / `stop()`; leave start
    intent on when backgrounding (do not `stop()` just for background)
  - subscribe to `operationalStatus` only (no beacon identities); handle
    `.degraded(.authenticationFailed)` for token-broker failures (Queued
    retained; retries continue; clears on successful mint or reconfigure)
  - optional `setDiagnosticsReporter` for host monitoring
  - never import `@_spi(SelectApp)` or `SelectBeaconAppSupport` in VIP
- [ ] Select internal app notes: additionally depend on
      `SelectBeaconAppSupport`; gate Start on `isStopFinalizePending`; use
      pending/open/active callbacks; show first-seen / last-seen / best RSSI /
      observations / lat-lng (label location timestamp **Cached location time**).
- [ ] Smoke-build BizStride (or a VIP sample target) against the tagged package
      on a real device.
- [x] Record known limitations in the release notes (e.g. production host still
      placeholder until replaced).

## Hardening / polish (not required for first VIP package)

- [x] Add CI (GitHub Actions) running
      `xcodebuild test -scheme SelectBeaconSDK-Package` on an iOS 17+ simulator
      with full Xcode — see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
      (PRs targeting `main`).
- [x] App Store Privacy Manifest (`PrivacyInfo.xcprivacy` on
      `SelectBeaconSDK`): declares Device ID (IDFV) + Precise Location for App
      Functionality, no tracking, no Required Reason APIs. Host still owns
      Info.plist location usage strings / permission prompts.
- [x] Public host diagnostics hook: `setDiagnosticsReporter` +
      `SelectBeaconDiagnosticsReporting` (coarse events only; no third-party
      monitoring SDK in this package; hosts wire their own backends).
- [x] **HTTPS-only** for staging and live auth/ingest: cleartext `http` base
      URLs and endpoints are rejected (`Environment.staging`, `APIEndpoint`,
      token broker, and ingest transport).
- [x] Durable-queue / dead-letter Data Protection:
      `FileProtectionType.completeUntilFirstUserAuthentication` on files and
      containing directory (migrates existing files on load).
- [x] Harness UI: surface first-seen / last-seen / best RSSI / observations /
      lat-lng / **Cached location time** on open + queued rows to match ingest
      fields.
- [x] Keep `Examples/BeaconTest` free of production keys; document how
      VIP/Select inject staging keys locally.
- [x] Align BeaconTest startup with `CONSUMER_UI_PROMPT.md`: harness still
      auto-starts after configure for convenience; optional manual-only start
      remains a polish item. SPI debug auto-ack is Select-harness-only (documented
      in BeaconTest README — not for VIP copy-paste).
- [x] **Upload forward policy (latency-first):** opportunistic post-enqueue /
      wake flush is the usual first drain when online; quiet debounce is a
      foreground coalescing backstop. Documented in `docs/architecture.md` §5b/§6.
      Batch-first (defer FG flush to debounce) is a non-goal unless product
      revisits. Related follow-ups only if needed: Tier B background
      `URLSession`, AppSupport uploading/retry visibility.
- [x] **Dead-letter cleanup**: age + count eviction (same `maxQueueSize` /
      `maxRecordAge` as pending) on dead-letter append and load; Select-only
      `clearDeadLetteredReports()` with the same stop gates as pending clear;
      pending clear still leaves dead letters.

## Done recently (do not re-open unless product asks)

- Observation-window aggregates and durable enqueue-on-close
- Flat JSON ingest fields (`first_seen`, `last_seen`, `best_rssi_dbm`, …; snake_case)
- Staging live auth (`/auth/v1` with app key + secret) + HTTP ingest
  (`/sdk/v1/detections` with Authorization)
- Upload coordinator (quiet debounce, max queue age, opportunistic full drain,
  bounded single-batch background wake flush, backoff)
- iBeacon region monitoring + ranging-on-wake (Always); When-In-Use remains
  foreground-only; host `UIBackgroundModes` required for real wakes
- Stop-finalize pending + Start gating semantics
- Cleanup refactor: unused SPI event stream removed, restart-safe path monitor,
  stop-finalize durability, shared delayed-action scheduler, split lifecycle tests

## Explicit non-goals (do not block completion)

- CoreBluetooth / Eddystone scanning
- SDK-owned permission prompts
- Resolving beacon serials in the SDK (backend only)
- Third-party dependencies inside `SelectBeaconSDK`
- Changing observation-window location aggregation rules unless product asks

## Suggested first VIP package stance

Ship a **tagged staging-capable package** once on-device smoke and staging E2E
upload pass, with release notes stating:

1. Detection, 60s windows, durable queue, and upload coordinator are implemented.
2. Staging uploads work with an explicit `environment: .staging(baseURL:)`.
3. Default production configure still uses `REPLACE_ME_PRODUCTION` until the
   confirmed host is substituted and a follow-up tag is cut.
