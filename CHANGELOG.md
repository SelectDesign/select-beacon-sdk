# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - TBD

First package drop for host apps and the Select-owned app.

### Added

- Core Location iBeacon region monitoring and ranging (Select fleet UUID).
- 60-second observation windows with absence close and durable enqueue.
- Store-and-forward upload coordinator (opportunistic flush, quiet debounce,
  max-age, backoff, bounded background wake flush).
- Live token broker (`/auth/v1`) and HTTP ingest (`/sdk/v1/detections`) against
  production host `https://ingestor.beacons.selectbrandhub.com`.
- Host-visible `.degraded(.authenticationFailed)` for broker failures.
- `SelectBeaconAppSupport` product for Select UI snapshots (active, open,
  pending, dead letter, stop-finalize).
- Host and Select integration guides under `docs/`.

### Known limitations

- Host and Select app keys/secrets still need provisioning against the token
  broker for each install.
- Background `URLSession` (Tier B) is intentionally out of scope: confirmed
  location-wake piggybacking; the SDK uses bounded wake flushes only.
