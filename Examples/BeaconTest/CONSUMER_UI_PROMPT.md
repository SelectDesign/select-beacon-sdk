# Prompt: Select Beacon debug UI (consumer app)

Use this brief to build (or regenerate) a SwiftUI debug screen for an iOS 17+
app that consumes **SelectBeaconSDK** and **SelectBeaconAppSupport**. Do not
import `@_spi(SelectApp)` in application code — use the AppSupport product only.

## Goal

Show three live sections:

1. **In range** — beacons heard within the SDK’s ~30s absence timeout
2. **Open summaries** — in-progress 60s observation windows (running aggregates)
3. **Queued for upload** — durable reports waiting for acknowledgement

Successfully acknowledged reports must **disappear** from the queued list via
AppSupport callbacks (do not keep a local “sent” history unless product asks).

## Setup (host app)

1. Host owns Core Location permission prompts and Info.plist usage strings.
2. Call `SelectBeaconSDK.configure(appKey:)` then register AppSupport callbacks,
   then `SelectBeaconSDK.shared.start()`.
3. On appear, also call `try await SelectBeaconAppSupport.shared.pendingReports()`
   to load queue records from a prior launch.
4. Optional for local demos only:  
   `SelectBeaconSDK.shared.selectInstallDebugAutoAckUploadSeams()`  
   (`@_spi(SelectApp)` on the SDK module) so flushes auto-acknowledge without a
   real VIP API. Production builds leave the deferred transport.

## Bindings

| Section        | Snapshot                  | Change callback                  |
| -------------- | ------------------------- | -------------------------------- |
| In range       | `currentBeacons`          | `onActiveBeaconsChanged`         |
| Open summaries | `currentOpenWindows`      | `onOpenWindowsChanged`           |
| Queued         | `pendingReports()`        | `onPendingReportsChanged`        |
| Stop finalize  | `isStopFinalizePending`   | `onStopFinalizePendingChanged`   |

### Start gating

After `stop()`, open windows clear **before** durable enqueue finishes. Do **not**
treat `currentOpenWindows == []` as “safe to start.” Gate Start on
`isStopFinalizePending == false` (seed the property on bind; also listen for
`onStopFinalizePendingChanged`).

A second `stop()` with no open windows does **not** clear finalize-pending early
while a cancelled finalize write may still be in flight; wait for the flag.

### In range (`ActiveBeacon`)

Show: major, minor, RSSI (dBm), last observed time.  
Do not treat presence as “report ready.”

### Open summaries (`OpenBeaconWindow`)

Show: major, minor, best RSSI, observation count, optional location,
window start, latest sighting time, and roughly how many seconds remain in the
60s window (`windowStartedAt + 60 - now`).

### Queued for upload (`PendingBeaconReport`)

Show: major, minor, best RSSI, observation count, optional location,
`windowStartedAt`, `latestTimestamp`, `queuedAt` (age vs ~5 minute max-queue-age).  
List is FIFO. Offline or API failures leave items here; the SDK retries (15s →
double → cap 300s after a failed attempt; offline skips without backoff). There
is no separate “retrying” status in AppSupport today — still show as queued.

## Explicit non-goals

- Do not request location permission from the SDK.
- Do not fabricate coordinates when `location` is nil.
- Do not invent batch JSON beyond “these records are eligible for the next
  upload batch(es).”
- Do not use CoreBluetooth or add third-party dependencies for this screen.

## Acceptance checks

- Sighting a Select beacon updates **In range** and **Open summaries**.
- After ~60s continuous presence or ~30s absence, a report moves to **Queued**
  and the open window clears or rolls over.
- With debug auto-ack (or a real acknowledging transport), after a flush the
  queued row disappears via `onPendingReportsChanged`.
- Relaunch with pending disk records still shows them after `pendingReports()`.
- Calling `stop()` with an open window sets `isStopFinalizePending == true`
  while open windows are already empty; the flag clears only after durable
  enqueue settles. Start remains gated until then.
- **Clear Queue** (or `clearPendingReports()`) is available only when detection
  is stopped and `isStopFinalizePending == false`. It empties durable pending
  reports, including recovering an unreadable queue file.
