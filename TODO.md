# SelectBeaconSDK — remaining work

Checklist for finishing the SDK and handing it to VIP as a consumable Swift
Package. Ordered roughly by dependency: production gates before a production
tag; packaging can proceed earlier with an explicit “staging uploads only”
limitation.

## Production gates (blocks production upload)

- [ ] Confirm and set the real production ingest host; replace
      `REPLACE_ME_PRODUCTION` in `APIEndpointDefaults` / configuration.
- [ ] Provision VIP (BizStride) and Select app keys against the token broker
      (`POST {base}/ingest/auth/v1`).
- [ ] End-to-end staging upload: configure `.staging(baseURL:)`, detect a real
      beacon, confirm flat JSON body lands in beacon-ingestor, HTTP 200 clears
      the durable queue.
- [ ] End-to-end production upload after the host URL is set (same path,
      production key + host).
- [x] Confirm with VIP/backend that wire attributes match ingest
      (`uuid`, `major`, `minor`, `best-rssi-dbm`, `observations`, `lat`/`lng`,
      `first-seen`, `last-seen`, `device-id`, `idempotency-key`) and that
      whole-batch ack on HTTP 200 is final. Backend must dedupe on
      `idempotency-key` (at-least-once delivery).
- [ ] Re-enable ingest auth: set `UploadAuthentication.isEnabled = true` once
      the token broker is ready (Bearer header + 401 refresh path).
- [ ] VIP confirmation for background `URLSession` (Tier B) if system-completed
      uploads while suspended are required beyond opportunistic wake flushes.

## On-device validation (blocks a trustworthy VIP drop)

- [ ] Physical iPhone smoke with `Examples/BeaconTest`: permission owned by
      host, in-range → open window → queued → upload/ack (staging or debug
      auto-ack).
- [ ] Physical iPad smoke for the same flow.
- [ ] When-In-Use: ranging pauses in background and resumes in foreground.
- [ ] Always + location background mode: region-monitoring wakes start short
      ranging bursts; enqueue works; background flush is at most one batch.
- [ ] Relaunch with pending disk records still visible via
      `SelectBeaconAppSupport.pendingReports()`.
- [ ] Staging vs production queue isolation (different `appKey` / base URL →
      separate storage namespaces).
- [ ] Stop-finalize: Start stays gated on `isStopFinalizePending` until durable
      enqueue settles.

## Package for VIP (distribution)

- [ ] Agree the Git remote VIP will depend on (this repo or a VIP-visible
      mirror) and access (org, deploy key, or public).
- [ ] Add `LICENSE` (or confirm VIP’s required license text) before the first
      tagged release.
- [ ] Add `CHANGELOG.md` (or release notes template) starting at the first tag.
- [ ] Cut an annotated semver tag (`v0.x` if uploads are staging-only;
      `v1.0.0` only after production gates).
- [ ] Push the tag; give VIP the SPM URL + exact version/tag to pin.
- [ ] VIP BizStride integration notes (one page):
  - depend on product `SelectBeaconSDK` only
  - host Info.plist location strings + optional Always / background mode
  - `configure(appKey:)` then `start()` / `stop()`
  - subscribe to `operationalStatus` only (no beacon identities)
  - never import `@_spi(SelectApp)` or `SelectBeaconAppSupport` in VIP
- [ ] Select internal app notes: additionally depend on
      `SelectBeaconAppSupport`; gate Start on `isStopFinalizePending`; use
      pending/open/active callbacks; show first-seen / last-seen / best RSSI /
      observations / lat-lng (label location timestamp **Cached location time**).
- [ ] Smoke-build BizStride (or a VIP sample target) against the tagged package
      on a real device.
- [ ] Record known limitations in the release notes (e.g. production host still
      placeholder until replaced).

## Hardening / polish (not required for first VIP package)

- [x] Add CI (GitHub Actions) running
      `xcodebuild test -scheme SelectBeaconSDK-Package` on an iOS 17+ simulator
      with full Xcode — see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
      (PRs targeting `main`).
- [ ] Add App Store Privacy Manifest (`.xcprivacy`) if required for the SDK’s
      APIs (location usage is host-declared; confirm with VIP’s App Store
      process).
- [ ] Wire host diagnostics: bridge `DiagnosticsReporter` events to VIP/Select
      Sentry (or equivalent) without shipping Sentry inside this package.
- [ ] Decide HTTPS-only for staging (today cleartext `http` is allowed if a
      caller supplies it).
- [ ] Decide durable-queue file protection / Data Protection expectations for
      on-disk beacon + location records.
- [ ] Harness UI: surface first-seen / last-seen / best RSSI / observations /
      lat-lng / **Cached location time** on open + queued rows to match ingest
      fields.
- [ ] Keep `Examples/BeaconTest` free of production keys; document how
      VIP/Select inject staging keys locally.
- [ ] Align BeaconTest with `CONSUMER_UI_PROMPT.md` (Clear Queue; SPI policy;
      optional no auto-start).

## Done recently (do not re-open unless product asks)

- Observation-window aggregates and durable enqueue-on-close
- Flat JSON ingest fields (`first-seen`, `last-seen`, `best-rssi-dbm`, …)
- Staging live auth (`/ingest/auth/v1`) + HTTP ingest (`/ingest/sdk/v1/detections`)
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
