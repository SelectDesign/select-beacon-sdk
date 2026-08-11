---
name: ios-sdk-change
description: >-
  Implement features and fixes in SelectBeaconSDK following package architecture,
  AppSupport/SPI boundaries, durable-queue and upload seams, and required tests.
  Use when changing Sources/, Package.swift, Examples/, or docs for this iOS
  Swift package, or when adding beacon detection, queue, upload, or AppSupport APIs.
---

# iOS SDK change (SelectBeaconSDK)

## Before coding

1. Read `docs/development-context.md`, relevant sections of `docs/architecture.md`, and `docs/decisions.md`.
2. Identify which product changes: `SelectBeaconSDK`, `SelectBeaconAppSupport`, or both.
3. Prefer extending existing seams (`DetectionEngine`, `DurableDetectionQueue`, `UploadTransport`, `DeviceIdentifying`) over new singletons.

## Implementation checklist

- [ ] Honor always-on SelectBeacon constraints (Core Location region monitoring +
      ranging, no permission requests, main-actor facade).
- [ ] Keep standard public API minimal; Select-only data goes through AppSupport / SPI.
- [ ] Inject time and I/O; pure stores take `now`.
- [ ] If host-visible state changes, mirror on AppSupport (snapshot + change callback; seed on init).
- [ ] Keep auth and ingest aligned with the confirmed endpoints and flat JSON
      detections contract (snake_case wire keys; `/auth/v1` with
      `app_key`/`app_secret`; Authorization on ingest); production remains
      disabled while its host is the placeholder. Never log secrets or tokens.
- [ ] Update docs when behavior or wire format changes (`architecture.md`, `decisions.md`, README / consumer prompt as needed).
- [ ] Add or extend unit tests for the new behavior and failure paths.

## Done when

- Package tests pass for `SelectBeaconSDK-Package` on an iOS 17+ simulator destination.
- No new third-party dependencies.
- Operational/status and diagnostics stay non-sensitive (no tokens or full payloads in logs).
