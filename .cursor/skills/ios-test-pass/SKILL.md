---
name: ios-test-pass
description: >-
  Run and green the SelectBeaconSDK package test suite on an iOS Simulator
  before calling work done. Use when finishing an implementation, after test
  failures, or when the user asks to run/verify tests for this Swift package.
---

# iOS test pass (SelectBeaconSDK)

## Steps

1. Resolve a simulator destination (`xcrun simctl list devices available` → prefer `iPhone 17` or an iOS 17+ iPhone UDID).
2. Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
PATH="/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH" \
xcodebuild test -scheme SelectBeaconSDK-Package \
  -destination 'platform=iOS Simulator,id=<UDID>'
```

3. On failure: fix compile/test issues; re-run. Prefer targeted `-only-testing:` while iterating, then a full suite before claiming done.
4. Do not require physical beacon hardware for unit tests. Device checklist remains in `Examples/BeaconTest/README.md` for on-device validation.

## Report

- Pass/fail, scheme, destination
- Short list of failures fixed (if any)
- Note if only a subset was run and full suite is still needed
