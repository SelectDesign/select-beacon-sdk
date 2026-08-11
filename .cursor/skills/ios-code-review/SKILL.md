---
name: ios-code-review
description: >-
  Review SelectBeaconSDK Swift changes for bugs, API-boundary regressions,
  concurrency/session durability, privacy, and missing tests. Use when the user
  asks for a code review, PR review, or /code-review on this iOS package.
---

# iOS code review (SelectBeaconSDK)

Review only; do not edit code unless the user explicitly asks for fixes.

## Priority order

1. Correctness / durability bugs (queue, `deliverySession`, stop-finalize pending, ack loops)
2. Behavioral regressions (start/stop, permission, window close, upload triggers)
3. Privacy / security (tokens, payloads, secrets in logs; permission requests; SPI misuse in apps)
4. API surface creep (public vs AppSupport vs internal)
5. Missing tests

## Checklist

- [ ] `start()` does not bump `deliverySession`; only `stop()` does when required by design
- [ ] Empty open windows ≠ finalize complete; pending flag semantics preserved
- [ ] Upload path: empty/no-op ack cannot spin; nil `deviceId` does not send empty ids
- [ ] Main-actor isolation respected; no blocking file I/O on the facade
- [ ] Standard consumers still cannot see beacon/queue PII without AppSupport
- [ ] Tests cover the changed path (including failure/cancel where relevant)

## Output format

Findings first, highest severity first. For each finding: severity, location (`file:line` when possible), why it matters. End with brief “what’s solid” only if useful. Do not restate the whole diff.
