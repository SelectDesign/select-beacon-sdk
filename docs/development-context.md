# Select Beacon SDK context

This package is the iOS beacon-detection SDK embedded by VIP's BizStride app to
crowdsource locations of Select retail assets.

## Non-negotiable constraints

- Use Core Location iBeacon region monitoring plus ranging; do not add
  CoreBluetooth scanning.
- Ship one Select UUID: `76F87C5C-AB0C-45C5-8E9A-19DEF7DC2911`.
- Identify beacons by UUID, Major, and Minor. The backend—not the SDK—resolves serials.
- Observe host-owned location authorization; never request permission.
- Require `SelectBeaconSDK.configure(appKey:appSecret:)` before `start()`.
  Configure stores credentials in memory only; it never starts ranging, reads
  disk, or uses the network.
- Production API configuration defaults internally to `REPLACE_ME_PRODUCTION`. Staging
  uses an explicit caller-supplied endpoint so multiple staging environments are supported.
- Target iOS 17+, keep `SelectBeaconSDK` main-actor isolated, and add no third-party dependencies.
- Keep the standard public API limited to configure, shared start/stop, and
  non-sensitive operational status.
- Keep beacon observations and durable queue data behind the Select-owned
  `SelectBeaconAppSupport` product and its SPI bridge. The adapter exposes
  active beacons separately from pending reports so the Select app does not
  infer report state from nearby observations.
- Aggregate beacon sightings into 60-second observation windows (`bestRSSI`,
  latest non-nil location, `latestTimestamp`, `observationCount`). Close on
  window duration or 30-second absence and enqueue immediately; pass time into
  testable logic. Do not use RSSI-improvement dedup for reporting.
- Stamp reports from a low-power cached location provider; never request
  location authorization or one-shot GPS per sighting.
- Persist finalized reports through an actor-isolated queue before Select
  adapter notification. Transmit with **store-and-forward**: enqueue immediately,
  drain later in connectivity-gated batches with offline retry (never per-event
  upload; never block capture on the network). Background region-wake flushes
  are bounded to one batch; full drains use quiet debounce, max-age, lifecycle,
  connectivity, and cold-start triggers. A cancelled delivery session must
  not emit delayed adapter updates. Upload auth is `{base}/auth/v1`
  (`app_key` + `app_secret` → short-lived token); ingest is
  `{base}/sdk/v1/detections` with `Authorization` once a usable
  environment host is configured.

## Safety requirements

Do not scan, request permissions, check authorization, or perform network work during
configuration or initialization. Avoid runtime force unwraps and degrade quietly when
authorization is unavailable. All logic must be testable without hardware or network.
