# SelectBeaconSDK — remaining work

Checklist for finishing the SDK and handing it to VIP as a consumable Swift Package.
Items are ordered roughly by dependency: production gates before a production package
tag; packaging/distribution can proceed earlier with an explicit “staging uploads only”
limitation.

## Production gates (blocks production upload)

- [ ] Confirm and set the real production ingest host; replace `REPLACE_ME_PRODUCTION` in `APIEndpointDefaults` / configuration.
- [ ] Provision VIP (BizStride) and Select app keys against the token broker (`POST {base}/ingest/auth/v1`).
- [ ] End-to-end staging upload: configure `.staging(baseURL:)`, detect a real beacon, confirm JSON:API body lands in beacon-ingestor, HTTP 200 clears the durable queue.
- [ ] End-to-end production upload after the host URL is set (same path, production key + host).
- [ ] Confirm with VIP/backend that wire attributes match ingest (`uuid`, `major`, `minor`, `best-rssi-dbm`, `observations`, `lat`/`lng`, `first-seen`, `last-seen`, `device-id`) and that whole-batch ack on HTTP 200 is final.
- [ ] Update `docs/releasing.md` / README so they no longer describe transport as “deferred until wire format is confirmed” (encoder + live HTTP seams exist; production host is the remaining blocker).

## On-device validation (blocks a trustworthy VIP drop)

- [ ] Physical iPhone smoke with `Examples/BeaconTest`: permission owned by host, in-range → open window → queued → upload/ack (staging or debug auto-ack).
- [ ] Physical iPad smoke for the same flow.
- [ ] When-In-Use: ranging pauses in background and resumes in foreground.
- [ ] Always + location background mode: background ranging behaves as documented.
- [ ] Relaunch with pending disk records still visible via `SelectBeaconAppSupport.pendingReports()`.
- [ ] Staging vs production queue isolation (different `appKey` / base URL → separate storage namespaces).
- [ ] Stop-finalize: Start stays gated on `isStopFinalizePending` until durable enqueue settles.

## Package for VIP (distribution)

- [ ] Agree the Git remote VIP will depend on (this repo or a VIP-visible mirror) and access (org, deploy key, or public).
- [ ] Add `LICENSE` (or confirm VIP’s required license text) before the first tagged release.
- [ ] Add `CHANGELOG.md` (or release notes template) starting at the first tag.
- [ ] Cut an annotated semver tag (`v0.x` if uploads are staging-only; `v1.0.0` only after production gates).
- [ ] Push the tag; give VIP the SPM URL + exact version/tag to pin.
- [ ] VIP BizStride integration notes (one page):  
  - depend on product `SelectBeaconSDK` only  
  - host Info.plist location strings + optional Always / background mode  
  - `configure(appKey:)` then `start()` / `stop()`  
  - subscribe to `operationalStatus` only (no beacon identities)  
  - never import `@_spi(SelectApp)` or `SelectBeaconAppSupport` in VIP
- [ ] Select internal app notes: additionally depend on `SelectBeaconAppSupport`; gate Start on `isStopFinalizePending`; use pending/open/active callbacks.
- [ ] Smoke-build BizStride (or a VIP sample target) against the tagged package on a real device.
- [ ] Record known limitations in the release notes (e.g. production host still placeholder until replaced).

## Hardening / polish (not required for first VIP package, recommended soon)

- [ ] Add CI (GitHub Actions or VIP’s system) running `xcodebuild test -scheme SelectBeaconSDK-Package` on an iOS 17+ simulator with full Xcode.
- [ ] Add App Store Privacy Manifest (`.xcprivacy`) if required for the SDK’s APIs (location usage is host-declared; confirm with VIP’s App Store process).
- [ ] Wire host diagnostics: bridge `DiagnosticsReporter` events to VIP/Select Sentry (or equivalent) without shipping Sentry inside this package.
- [ ] Decide fate of SPI `BeaconReportStatus.uploading` / `.acknowledged` (implement real transitions or remove/document as unused).
- [ ] Harness UI: surface first-seen / last-seen / best RSSI / observations / lat-lng on open + queued rows to match ingest fields (see prior observation-fields brief).
- [ ] Keep `Examples/BeaconTest` free of production keys; document how VIP/Select inject staging keys locally.

## Explicit non-goals (do not block completion)

- CoreBluetooth / Eddystone scanning
- SDK-owned permission prompts
- Resolving beacon serials in the SDK (backend only)
- Third-party dependencies inside `SelectBeaconSDK`
- Changing observation-window location aggregation rules unless product asks

## Suggested first VIP package stance

Ship a **tagged staging-capable package** once on-device smoke and staging E2E upload pass, with release notes stating:

1. Detection, 60s windows, durable queue, and upload coordinator are implemented.
2. Staging uploads work with an explicit `environment: .staging(baseURL:)`.
3. Default production configure still uses `REPLACE_ME_PRODUCTION` until the confirmed host is substituted and a follow-up tag is cut.
