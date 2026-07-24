# Releasing SelectBeaconSDK

This repository produces a Swift Package. There is no server deployment step:
releasing means validating the package, creating an immutable Git version tag,
and updating consuming iOS applications to that version.

## 1. Confirm release scope

Before building, record:

- The release version using semantic versioning, for example `v1.2.0`.
- Whether the change affects the standard `SelectBeaconSDK` product, the
  Select-only `SelectBeaconAppSupport` product, or both.
- Any public API removals or behavior changes. Treat those as a major-version
  change unless the existing release policy explicitly permits otherwise.

Do not release production behavior based only on simulator results. iBeacon
ranging requires real iPhone or iPad hardware.

## 2. Satisfy production gates

Do not create a production release until all applicable gates are complete:

- Replace `REPLACE_ME_PRODUCTION` with the confirmed production API endpoint.
- Validate the Select token-broker endpoint and app-key provisioning process.
- Confirm the backend's upload payload and acknowledgement contract.
- Implement and test the production upload coordinator.

At present, the SDK detects beacons, aggregates observation windows, persists
eligible reports locally, and includes a debounced upload coordinator behind
deferred transport/auth seams until VIP confirms the wire format. A release
before production transport is wired must be described as detection and
durable-queue support with coordinator seams in place.

## 3. Prepare a supported build machine

Use a Mac with a full Xcode installation that supports:

- iOS 17 or later SDKs
- Swift 6 language mode
- An installed iOS Simulator runtime

Verify that the active developer directory points to full Xcode, not Command
Line Tools:

```sh
xcode-select -p
xcodebuild -version
```

If the first command returns `/Library/Developer/CommandLineTools`, select the
approved Xcode installation before running iOS builds.

## 4. Run automated validation

From the repository root:

```sh
swift package dump-package
xcodebuild -list
xcodebuild test \
  -scheme '<scheme listed by xcodebuild -list>' \
  -destination 'platform=iOS Simulator,name=<installed-simulator-name>'
```

`xcodebuild -list` reports the automatically generated package scheme. Its name
may be `SelectBeaconSDK-Package`, so do not assume a particular scheme name.
Use an installed simulator name from:

```sh
xcrun simctl list devices available
```

The package imports UIKit and Core Location, so plain `swift test` on macOS is
not a supported verification command.

The simulator suite must pass before device testing. It validates:

- Observation-window aggregation and presence-expiry rules
- Location cache stamping (including nil location)
- Queue persistence, rollback on failed writes, reload, and legacy migration
- Debounced batch upload, offline retry, and opportunistic background flush
- Lifecycle, permission, and temporary ranging-pause behavior
- The core SDK to Select-app adapter boundary

## 5. Run on-device smoke tests

Build the `Examples/BeaconTest` harness into a signed development app. It uses
both package products:

- `SelectBeaconSDK`
- `SelectBeaconAppSupport`

Use a non-production app key. Never commit a production key to the harness or
repository.

On a physical iPhone and iPad, verify:

1. The host app supplies its own location permission descriptions.
2. The SDK never displays its own permission prompt.
3. A Select beacon appears in the active-beacon view with UUID, major, minor,
   and RSSI.
4. A reportable window appears in the pending-report snapshot after close
   (absence timeout, window rollover, or `stop()`).
5. Additional sightings inside an open window update aggregates without adding
   another queue record until the window closes.
6. Pending records survive an app relaunch.
7. With When-In-Use permission, ranging pauses in the background and resumes
   in the foreground.
8. With Always permission and the host's location background mode enabled,
   ranging continues in the background as expected.
9. Staging uses the intended explicit endpoint and does not share its queue
   namespace with production.

The iOS Simulator cannot validate physical beacon detection.

## 6. Review the public integration contract

Verify the release documentation matches the compiled package:

- Standard consumers use `SelectBeaconSDK` for configuration, start/stop, and
  operational status.
- The Select internal app additionally uses `SelectBeaconAppSupport` for
  active-beacon and pending-report snapshots.
- Application source must not import the `SelectApp` SPI directly.

Review [`README.md`](../README.md), [`architecture.md`](architecture.md),
[`development-context.md`](development-context.md), and
[`decisions.md`](decisions.md) for outdated examples, placeholder endpoints,
or claims that reports are uploaded when they are only queued.

## 7. Publish the package version

After validation:

1. Commit the release changes through the normal review process.
2. Create an annotated, immutable Git tag:

   ```sh
   git tag -a v<version> -m "Release v<version>"
   git push origin v<version>
   ```

3. Update each consuming app's Swift Package dependency to the new tag.
4. Build and smoke-test each consuming app with its production-like
   configuration.
5. Record the version, test evidence, supported Xcode version, and known
   limitations in the release notes.

Do not move or overwrite an existing release tag. If a released version needs
to be withdrawn, publish a new patch version or revert the consuming app to
the prior known-good tag.

## Release checklist

- [ ] Simulator tests pass with full Xcode.
- [ ] Physical iPhone and iPad smoke tests pass.
- [ ] Permissions and background behavior are verified.
- [ ] Production endpoint and upload readiness are confirmed, or release notes
      clearly state that uploads are not implemented.
- [ ] Standard and Select-app product integration paths are documented.
- [ ] Version tag and release notes are prepared.
