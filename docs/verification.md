# Verification

## Efficient UI update — 2026-09-16

The previous running release measured 31.6 MiB footprint (35.8 MiB peak) after over nine hours. The AppKit status-item/on-demand popover version measured 17.7 MiB before opening its dashboard. A separate explicit `--verify-ui-lifecycle` run exercised three open/close cycles: approximately 17.5 MiB initially, 31–32 MiB open, and 26.9–30.2 MiB closed. Framework/allocator caches survive closing, so the initial 44% reduction should not be interpreted as the sustained saving after dashboard use. These are short observations, not a long-running leak benchmark. The status-item symbol is also updated only when its meaning changes to avoid redundant image/layout work every sample.

All 26 tests passed after changing the UI lifecycle. Release packaging/signature checks passed. The actual dashboard was exported and visually inspected with the new Canvas sparkline. UI automation through System Events was unavailable because the terminal lacks Accessibility permission; the explicit diagnostic mode exercises real popover opening and closing without requiring that permission. It exits after the cycles. No notification was deliberately sent during verification.

The dashboard is released when closed. Its scroll/expansion state resets, but monitoring history, session totals, thresholds, and notification preferences remain in the model. The two-path sparkline retains separate read/write colors, MiB/s scale, threshold line, and breaks across gaps over ten seconds. No Swift Charts import remains.

After avoiding redundant status-symbol image updates, the final build's three-cycle diagnostic measured 17.5 MiB initially, approximately 31.6–31.7 MiB open, and approximately 27 MiB after the first two closes. Reproduce with `dist/SwapWatch.app/Contents/MacOS/SwapWatch --verify-ui-lifecycle`; it temporarily displays its own menu item/popover and then exits.

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

No real workload was used to deliberately force heavy swap writes or memory pressure. Those scenarios use deterministic tests. Notifications are enabled by default and request macOS permission on first launch; no permission was requested or notification sent during this validation run. Users can opt out from Alerts & thresholds. Interactive menu controls, sleep/wake behavior, and sustained idle resource use were reviewed in code but not exhaustively automated. Only this Mac was used for runtime verification; macOS 13 is the deployment target, not a separately tested machine.

The standalone Command Line Tools installation reported SDK/PackageDescription version mismatches. The full Xcode installation worked after the user completed its license and onboarding.
