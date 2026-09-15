# Verification

Verified locally on macOS 26.6.2, Apple silicon, using full Xcode's Swift 6.4 toolchain on 2026-09-15.

- `swift test`: 20 tests passed, zero failures. Includes 4 KiB/16 KiB pages, read/write direction, baseline/session accounting, counter regression, gaps, page-size changes, invalid thresholds, overflow-safe conversion, irregular rolling-window clipping, frequent/sustained/churn classification, bounded history, and a native sampler smoke test.
- `bash scripts/build-app.sh`: release build passed; local app bundle created and ad-hoc signature verified.
- `plutil -lint Support/Info.plist` and `bash -n scripts/build-app.sh`: passed.
- Packaged app `--diagnose`: three live samples succeeded with no unavailable metrics. Reported 16,384-byte pages, 24 GiB RAM, normal pressure, and approximately 3.32 GiB occupied swap. Swap-outs stayed flat while swap-ins increased. This validates occupancy/activity separation without inducing pressure.
- Packaged app `--screenshot /tmp/swapwatch-dashboard.png`: exported the actual SwiftUI dashboard; visually checked normal pressure, idle writes, active reads, occupancy, warm-up, and the low-headroom notice. This early snapshot is taken before enough points exist for the chart.
- Launched `dist/SwapWatch.app` using Launch Services and confirmed its process remained running. A subsequent process snapshot showed 0.0% CPU and about 72 MiB RSS; this is a point-in-time observation, not a benchmark.

## Compatibility issue caught and fixed

The installed SDK's VM statistics structure includes newer revisions (104 integer slots). The running kernel returns an older revision (40 slots). The sampler now provides the full buffer but requires only the fields it actually consumes, rather than rejecting every shorter response. The native smoke test guards this regression.

## Limits of verification

No real workload was used to deliberately force heavy swap writes or memory pressure. Those scenarios use deterministic tests. Notification delivery depends on user opt-in and macOS settings; no permission was requested or notification sent during validation. Interactive menu controls, sleep/wake behavior, and sustained idle resource use were reviewed in code but not exhaustively automated. Only this Mac was used for runtime verification; macOS 13 is the deployment target, not a separately tested machine.

The standalone Command Line Tools installation reported SDK/PackageDescription version mismatches. The full Xcode installation worked after the user completed its license and onboarding.
