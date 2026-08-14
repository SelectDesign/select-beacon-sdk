# Select app integration

Checklist for the Select-owned app that depends on **SelectBeaconSDK** and
**SelectBeaconAppSupport**. Standard hosts should use
[host-integration.md](host-integration.md) instead.

## Package

- Depend on **`SelectBeaconSDK`** and **`SelectBeaconAppSupport`**.
- Wire AppSupport against the shared SDK instance (see package README).
- Do not expose `@_spi(SelectApp)` to non-Select code paths.

## Start gating

- Gate Start on **`isStopFinalizePending`** /
  **`onStopFinalizePendingChanged`**.
- An empty open-window snapshot after `stop()` is **not** proof that durable
  enqueue finished.

## Snapshots and callbacks

Wire:

| Concern       | Snapshot                | Callback                       |
| ------------- | ----------------------- | ------------------------------ |
| Presence      | `currentBeacons`        | `onActiveBeaconsChanged`       |
| Open minute   | `currentOpenWindows`    | `onOpenWindowsChanged`         |
| Queued        | `pendingReports()`      | `onPendingReportsChanged`      |
| Dead letter   | `deadLetteredReports()` | `onDeadLetteredReportsChanged` |
| Stop finalize | `isStopFinalizePending` | `onStopFinalizePendingChanged` |

UI fields for open / pending / dead-letter rows:

- first-seen, last-seen, best RSSI, observation count
- lat / lng when present
- label the location timestamp **Cached location time** (coarse cache; not a
  fresh GPS fix per sighting)

`currentBeacons` is presence; open windows are in-progress summaries; pending
is the durable FIFO until upload acknowledgement.

## Clear APIs

- Call `clearPendingReports()` / `clearDeadLetteredReports()` only while
  detection is stopped and stop-finalize has settled.
- Pending clear does not empty dead letters (and vice versa).

## Harness vs product

- Full UI brief:
  [Examples/BeaconTest/CONSUMER_UI_PROMPT.md](../Examples/BeaconTest/CONSUMER_UI_PROMPT.md).
- SPI debug auto-ack (`selectInstallDebugAutoAckUploadSeams`) is
  Select-harness-only — not for standard host apps.

## Further reading

- [host-integration.md](host-integration.md) — standard-host constraints
- [README.md](../README.md) — AppSupport overview
- [architecture.md](architecture.md) — queue, upload, and stop-finalize design
