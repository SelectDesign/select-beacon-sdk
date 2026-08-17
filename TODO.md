# SelectBeaconSDK — remaining work

Open items only. Completed work lives in git history / `CHANGELOG.md`.

## Package / VIP handoff

- [ ] Cut an annotated semver tag (`v0.x` pre-1.0, or `v1.0.0` when gates allow).
- [ ] Push the tag; give VIP the SPM URL + exact version/tag to pin
      (`https://github.com/SelectDesign/select-beacon-sdk.git`).
- [ ] Smoke-build the VIP host app (or a VIP sample target) against the tagged
      package on a real device.

## Explicit non-goals (do not block completion)

- CoreBluetooth / Eddystone scanning
- SDK-owned permission prompts
- Resolving beacon serials in the SDK (backend only)
- Third-party dependencies inside `SelectBeaconSDK`
- Changing observation-window location aggregation rules unless product asks
- Background `URLSession` (Tier B): confirmed uploads can piggyback on
  location/region wakes; keep wake-bounded flush as the design (avoid
  noticeable battery/data spikes)
