# SwapWatch

<img src="docs/assets/swap-watch.png" alt="SwapWatch orange glass stopwatch icon" width="160" height="160">

**Run local LLMs with a clearer view of what they're asking of your Mac.**

SwapWatch is a focused macOS menu-bar app that shows memory pressure, swap usage, and estimated swap-write activity. See when a memory-heavy workload starts leaning on disk—and when that becomes a sustained pattern worth investigating.

## Why use it?

A large swap number isn't the same as constant disk writes. SwapWatch helps you tell the difference between memory sitting in swap and active back-and-forth traffic, without keeping Activity Monitor open.

- **Know when to ease the workload.** Visible warnings highlight frequent writes, sustained writes, and swap churn so you can consider a smaller model, shorter context, or fewer competing apps.
- **Watch the writes that matter.** See current read/write rates, a ten-minute activity graph, and estimated write totals for your monitoring session.
- **Get interrupted when you need to look.** macOS notifications flag concerning activity even when the dashboard is closed. Notifications are **on by default**, require macOS permission, and can be turned off in Alerts & thresholds.
- **Keep the monitor lightweight.** Native Swift and AppKit, no third-party packages or polling subprocesses. The dashboard is created only when opened and released when closed.
- **Keep your work local.** No accounts, telemetry, cloud services, or disk-based monitoring history.

<img src="docs/assets/dashboard.png" alt="SwapWatch dashboard showing memory pressure, swap occupancy, read and write rates, activity history, and memory and storage metrics" width="390">

*The actual dashboard with live readings from a Mac. Hover over metrics for explanations.*

## Get SwapWatch

Requires **macOS 13 or newer** and Xcode to build. There isn't a downloadable release yet; build the app locally:

```sh
git clone git@github.com:danieljurek/swap-watch.git
cd swap-watch
bash scripts/build-app.sh
open dist/SwapWatch.app
```

This repository is currently private, so cloning requires repository access. If Xcode requests onboarding, open Xcode and complete its license and component installation first.

SwapWatch appears in your menu bar, not the Dock. Click it to open the dashboard, adjust warning thresholds, or quit. To start it automatically, add the built app in **System Settings → General → Login Items**.

## What the warnings mean

Sustained heavy writes can accelerate SSD wear, but **SwapWatch is a workload monitor, not an SSD health test or failure predictor**. It estimates compressed swap transfers from system-wide macOS counters; it does not measure physical NAND writes, remaining endurance, or which app caused the swapping. It observes activity and alerts you—it never stops models, kills processes, or changes macOS swap settings.

Samples arrive approximately every two seconds. By default, warnings identify an average write rate of at least 5 MiB/s, or writes of at least 1 MiB/s during 25% of the observed time in a rolling 60-second window. Classification needs at least 30 seconds of observations. Significant reads alongside these writes indicate churn. Critical memory pressure can alert immediately; repeated notifications have a five-minute cooldown. These thresholds are adjustable operational heuristics, **not SSD damage limits**.

Session totals exclude activity before launch and missed sampling intervals, and reset when you quit or click Reset. Your preferences persist. Notification settings show macOS permission separately from your opt-in preference; Focus can still silence permitted notifications.

For the details behind the measurements, see [memory and SSD research](docs/memory-and-ssd.md).

## Development

```sh
swift test
dist/SwapWatch.app/Contents/MacOS/SwapWatch --diagnose
```

The build uses the Swift toolchain selected by `xcode-select` (or an explicit `DEVELOPER_DIR`), generates the app icon from `swap-watch.png`, and applies a local ad-hoc signature. It is not a notarized distribution build. Generated build files are excluded from Git.

See [verification notes](docs/verification.md) for testing and runtime checks.
