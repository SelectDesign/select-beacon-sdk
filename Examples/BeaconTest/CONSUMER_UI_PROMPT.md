# Prompt: Select Beacon debug UI (consumer app)

Use this brief to build (or regenerate) a SwiftUI debug screen for an iOS 17+
app that consumes **SelectBeaconSDK** and **SelectBeaconAppSupport**. Do not
import `@_spi(SelectApp)` in application code — use the AppSupport product only.

## Goal

Show four live sections:

1. **In range** — beacons heard within the SDK’s ~30s absence timeout
2. **Open summaries** — in-progress 60s observation windows (running aggregates)
3. **Queued for upload** — durable reports waiting for acknowledgement
4. **Dead letter** — durable reports removed from pending after non-retryable
   failure or max upload attempts (diagnostics only; not re-uploaded)

Successfully acknowledged reports must **disappear** from the queued list via
AppSupport callbacks (do not keep a local “sent” history unless product asks).
Poison / max-attempt failures must leave Queued and appear under Dead letter.

## Setup (host app)

1. Host owns Core Location permission prompts and Info.plist usage strings.
2. Call `SelectBeaconSDK.configure(appKey:appSecret:environment:)` (staging
   requires an explicit base URL; production is the default), then register
   AppSupport callbacks, then `SelectBeaconSDK.shared.start()`.
3. Optionally observe `SelectBeaconSDK.shared.onOperationalStatusChanged` for
   session UX, including `.degraded(.authenticationFailed)` when the token
   broker fails (Queued is retained; upload retries; clears on successful mint).
4. On appear, also call `try await SelectBeaconAppSupport.shared.pendingReports()`
   and `try await SelectBeaconAppSupport.shared.deadLetteredReports()` to load
   queue records from a prior launch.
5. Optional for local demos only:  
   `SelectBeaconSDK.shared.selectInstallDebugAutoAckUploadSeams()`  
   (`@_spi(SelectApp)` on the SDK module) so flushes auto-acknowledge without a
   real API. Without auto-ack, staging and production use live `/auth/v1` +
   ingest Authorization when a usable HTTPS host is configured. Debug auto-ack
   drains Queued on success and does **not** dead-letter.

## Bindings

| Section        | Snapshot                | Change callback                |
| -------------- | ----------------------- | ------------------------------ |
| In range       | `currentBeacons`        | `onActiveBeaconsChanged`       |
| Open summaries | `currentOpenWindows`    | `onOpenWindowsChanged`         |
| Queued         | `pendingReports()`      | `onPendingReportsChanged`      |
| Dead letter    | `deadLetteredReports()` | `onDeadLetteredReportsChanged` |
| Stop finalize  | `isStopFinalizePending` | `onStopFinalizePendingChanged` |

### Start gating

After `stop()`, open windows clear **before** durable enqueue finishes. Do **not**
treat `currentOpenWindows == []` as “safe to start.” Gate Start on
`isStopFinalizePending == false` (seed the property on bind; also listen for
`onStopFinalizePendingChanged`).

A second `stop()` with no open windows does **not** clear finalize-pending early
while the durable finalize batch is still in flight; wait for the flag.

### In range (`ActiveBeacon`)

Show: major, minor, RSSI (dBm), last observed time.  
Do not treat presence as “report ready.”  
Rows are ordered by UUID → major → minor from AppSupport (stable when RSSI
updates); do not re-sort in the client.

### Open summaries (`OpenBeaconWindow`)

Show: major, minor, best RSSI, observation count, optional location,
window start, latest sighting time, and roughly how many seconds remain in the
60s window (`windowStartedAt + 60 - now`).

### Queued for upload (`PendingBeaconReport`)

Show: major, minor, best RSSI, observation count, optional location,
`windowStartedAt`, `latestTimestamp`, `queuedAt` (age vs ~5 minute max-queue-age).  
List is FIFO. Offline or retryable API failures leave items here; the SDK retries
(15s → double → cap 300s after a failed attempt; offline skips without backoff).
There is no separate “retrying” status in AppSupport today — still show as queued.

### Dead letter (`PendingBeaconReport`)

Same row fields as Queued. These will **not** retry. Bounded by the same max
size/age as pending (oldest dropped). `clearPendingReports()` clears pending
only; use `clearDeadLetteredReports()` (or **Clear Dead Letter**) to empty this
list. Both clears require detection stopped and `isStopFinalizePending == false`.

## Explicit non-goals

- Do not request location permission from the SDK.
- Do not fabricate coordinates when `location` is nil.
- Do not invent batch JSON beyond “these records are eligible for the next
  upload batch(es).”
- Do not use CoreBluetooth or add third-party dependencies for this screen.

## Acceptance checks

- Sighting a Select beacon updates **In range** and **Open summaries**.
- In range order stays UUID → major → minor across RSSI refreshes.
- After ~60s continuous presence or ~30s absence, a report moves to **Queued**
  and the open window clears or rolls over.
- With debug auto-ack (or a real acknowledging transport), after a flush the
  queued row disappears via `onPendingReportsChanged` (no Dead letter entry).
- After a poison / max-attempt dead-letter, the item leaves Queued and appears
  under Dead letter via `onDeadLetteredReportsChanged`.
- Relaunch with pending or dead-letter disk records still shows them after the
  corresponding async load.
- Calling `stop()` with an open window sets `isStopFinalizePending == true`
  while open windows are already empty; the flag clears only after durable
  enqueue settles. Start remains gated until then.
- **Clear Queue** (or `clearPendingReports()`) is available only when detection
  is stopped and `isStopFinalizePending == false`. It empties durable pending
  reports, including recovering an unreadable queue file; Dead letter is unchanged.
- **Clear Dead Letter** (or `clearDeadLetteredReports()`) uses the same gates and
  empties dead letters only; pending is unchanged.
