# BeaconTest device checklist

Build this source into an iOS harness app that imports both `SelectBeaconSDK`
and the Select-owned `SelectBeaconAppSupport` product. Use a debug-only app
key; do not commit production keys.

The harness UI has three beacon sections plus session controls (see
[CONSUMER_UI_PROMPT.md](CONSUMER_UI_PROMPT.md)):

- **Session** — Start/Stop; Start stays disabled while `isStopFinalizePending`
- **In range** — active beacons
- **Open summaries** — in-progress 60s windows
- **Queued for upload** — durable FIFO (drains after debug auto-ack flush)

Run the following checks on both a physical iPhone and iPad:

1. Grant location permission in the host before starting the SDK. Confirm no SDK
   permission prompt appears.
2. Detect a Select beacon and verify its UUID/major/minor/RSSI appear under
   **In range**, and aggregates (including seconds remaining) appear under
   **Open summaries**.
3. Wait for window close (~60s continuous or ~30s absence) and confirm a row
   appears under **Queued for upload**.
4. Background or otherwise trigger a flush with debug auto-ack installed and
   confirm the queued row disappears after acknowledgement.
5. With an open window, tap **Stop**: open summaries clear immediately,
   “Finalizing stop…” appears, and **Start** stays disabled until finalize
   pending clears. Then Start works again.
6. Run with Footmarks enabled and confirm both SDKs coexist.
7. Change permission from Always or When In Use to denied/restricted; ranging stops
   quietly. Restore permission and confirm it resumes only after `start()` intent exists.
8. With When In Use authorization, background the app and confirm detections stop;
   foreground it and confirm they resume.
9. With Always authorization and the host's location background mode enabled, verify
   region-monitoring wakes can resume detection (short ranging bursts) while the
   app is backgrounded. Force-closing the app is not a supported
   background-detection scenario. Background upload after a wake should attempt
   at most one batch; remaining queue rows stay until a later full drain.
10. Disable connectivity, detect a beacon through window close, relaunch, and verify
    the durable queue still shows pending reports until a successful ack path runs.
