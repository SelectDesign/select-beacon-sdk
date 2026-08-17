# Host integration

One-page checklist for standard apps that embed **SelectBeaconSDK** only.
For Select-owned UI (beacons, queue, stop-finalize), see
[select-app-integration.md](select-app-integration.md).

## Package

- Depend on product **`SelectBeaconSDK` only**.
- Do **not** depend on `SelectBeaconAppSupport`.
- Do **not** import `@_spi(SelectApp)`.
- SPM: `https://github.com/SelectDesign/select-beacon-sdk.git` — pin to an
  exact published tag (not a floating branch). First release: **`v1.0.0`**.

```swift
.package(
    url: "https://github.com/SelectDesign/select-beacon-sdk.git",
    exact: "1.0.0"
)
```

## Host requirements

- Add Info.plist location usage strings (host-owned prompts; the SDK never
  requests permission).
- For background / screen-off wakes: **Always** authorization **and** location
  background mode (`UIBackgroundModes` / Xcode capability). Always alone is
  not enough. (host already enables both; other hosts must match.)
- The SDK uses its own Core Location managers for beacon region monitoring and
  ranging. Hosts do not need to forward location callbacks for detection;
  leave `start()` intent on so the SDK can run in the OS wake window.
- Background uploads are intended to run in those wake windows (bounded
  single-batch flush). Avoid integrating patterns that keep the radio busy in
  the background beyond that — field users notice battery spikes.

## Lifecycle

```swift
import SelectBeaconSDK

SelectBeaconSDK.configure(
    appKey: appKey,
    appSecret: appSecret
)

SelectBeaconSDK.shared.onOperationalStatusChanged = { status in
    // Configuration, permission, ranging, auth, or other recoverable state.
}

SelectBeaconSDK.shared.start()
```

- Call `stop()` only when distributor-level detection should end (not merely
  because the app entered background). Leaving start intent on preserves
  region monitoring under Always + background mode.
- Production ingest/auth uses the package default host
  (`https://ingestor.beacons.selectbrandhub.com`).

## Status only

- Observe **`operationalStatus`** / **`onOperationalStatusChanged`** only.
- Do not expect beacon identities, RSSI, or queue records from the standard
  product.
- Handle `.degraded(.authenticationFailed)`: Queued reports stay on disk;
  upload keeps retrying; clears on the next successful token mint or a
  successful `configure`. Transient network / 5xx / 429 do not change
  operational status.

## Optional diagnostics

```swift
SelectBeaconSDK.shared.setDiagnosticsReporter(hostReporter)
// Pass nil to clear.
```

Forward coarse events only. Never log secrets, tokens, full payloads, or
beacon identities.

## Further reading

- [README.md](../README.md) — overview and public API detail
- [architecture.md](architecture.md) — store-and-forward and upload triggers
