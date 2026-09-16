# SwapWatch

A local Swift menu-bar monitor for macOS 13 or newer. Watch memory pressure, swap occupancy, and estimated swap reads/writes while running local LLMs.

## Build and run

```sh
bash scripts/build-app.sh
open dist/SwapWatch.app
```

The app lives in the menu bar, with no Dock icon. Click its status item for the dashboard and settings. Quit from the dashboard. The build script uses the Swift toolchain selected by `xcode-select` (or an explicit `DEVELOPER_DIR`). There are no third-party packages or network services.

If Xcode requests onboarding, complete `sudo xcodebuild -license` in Terminal and let Xcode finish installing its components. A local ad-hoc signature is applied during packaging; this is not a notarized distribution build.

```sh
swift test
dist/SwapWatch.app/Contents/MacOS/SwapWatch --diagnose
```

Diagnostics read a few real samples and exit. The development sandbox may deny sysctl reads; run the built app normally from Finder or Terminal. Unavailable readings are shown explicitly.

## What to watch

- **Memory pressure:** macOS's normal / warning / critical state. It is not a percentage of RAM used, and this coarse state is not a reproduction of Activity Monitor's graph.
- **Swap used:** current occupancy. Allocated swap is the current backing allocation, not a hard limit; macOS can grow it.
- **Swap writes:** estimated outgoing compressed swap I/O per second. Repeated writes are the relevant exposure when considering SSD wear.
- **Swap reads:** useful for spotting back-and-forth activity and slow inference. Reads are not added to write totals.
- **Session writes:** estimated swap writes observed while this app runs. It excludes missed intervals, sleep gaps, and activity before launch. It resets on quit or manual reset.
- **Frequent / sustained / churning:** configurable workload warnings. These are operational heuristics, not SSD endurance specifications.

Sampling runs every two seconds. The detector uses a rolling 60-second window and needs 30 seconds of valid observations before classifying sustained or frequent activity. Defaults: sustained writes average at least 5 MiB/s; frequent writes occur in at least 25% of observed time at 1 MiB/s or more. Significant reads alongside either condition produce a churn warning. Disk headroom is flagged below 10 GiB or 10% free; these are configurable activity thresholds and a fixed space heuristic, not SSD safety limits. A chart retains up to ten minutes in memory. Gaps over ten seconds, counter regressions, or page-size changes reset the rate baseline. No history is written to disk.

Notification banners are enabled by default because sustained swap writes may add SSD traffic during a memory-heavy workload. On first launch, macOS asks for notification permission; the Alerts & thresholds control is an explicit opt-out. Frequent, sustained, and churn alerts need the observation warm-up; critical pressure can alert immediately. A five-minute cooldown limits repeated banners. Settings persist locally. There is no background helper, automatic process killing, swap configuration change, or automatic login registration. To start at login, you can add the built app in System Settings → General → Login Items.

## Scope

The alert checkbox records your preference independently of macOS permission. If permission is denied or an authorization request fails, the checkbox stays on and the settings UI explains the problem. The app checks authorization, alert availability, and banner style through Apple's `UNUserNotificationCenter.notificationSettings()` API. Open Alerts & thresholds to refresh the status, or use Refresh Permission after changing System Settings → Notifications → SwapWatch. Focus settings can still silence permitted alerts.

SwapWatch measures **system-wide** VM activity; it cannot assign swap writes to a particular model or process. It does not measure physical NAND writes, SMART wear percentage, or remaining SSD life. The disk-space warning is a headroom warning. See [the research notes](docs/memory-and-ssd.md) for the measurement model, sources, and practical LLM guidance.
