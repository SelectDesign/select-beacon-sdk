# Host integration

One-page checklist for standard apps that embed **SelectBeaconSDK** only.
For Select-owned UI (beacons, queue, stop-finalize), see
[select-app-integration.md](select-app-integration.md).

## Package

- Depend on product **`SelectBeaconSDK` only**.
- Do **not** depend on `SelectBeaconAppSupport`.
- Do **not** import `@_spi(SelectApp)`.
- SPM: `https://github.com/SelectDesign/select-beacon-sdk.git` — pin to an
  exact published tag (not a floating branch).

## Host requirements

- Add Info.plist location usage strings (host-owned prompts; the SDK never
  requests permission).
- For background / screen-off wakes: **Always** authorization **and** location
  background mode (`UIBackgroundModes` / Xcode capability). Always alone is
  not enough.

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
