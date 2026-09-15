# macOS memory, local LLMs, and SSD writes

Research date: 2026-09-15. The app uses native macOS interfaces and intentionally distinguishes direct measurements from heuristics.

## A backend developer's mental model

Think of RAM as a managed cache plus a working set. macOS can reclaim file-backed cache, compress inactive memory in RAM, and move compressed segments to swap. Wired memory must remain resident. Compression itself uses CPU and RAM; it does not imply a disk write. Low free RAM alone is not a useful alarm because reusable file cache occupies otherwise idle RAM. Apple's pressure indicator accounts for factors including swap rate, wired memory, and cached memory. [Apple: Activity Monitor memory usage](https://support.apple.com/en-gb/guide/activity-monitor/actmntr1004/mac)

The useful analogy is a database gauge versus a throughput counter: swap occupancy is the current amount stored, whereas the change in the swap-out counter reveals ongoing writes. A workload can recycle occupied swap and generate writes without a growing footprint. Conversely, a nonzero footprint does not establish that new writes occurred during the last interval. The kernel maintains separate occupancy and lifetime swap counters. [Apple XNU VM statistics](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h)

On Apple silicon, the CPU and GPU share physical memory. A model's memory demand competes with the rest of the machine; the GPU does not provide an independent pool equal to the advertised unified memory. Metal also exposes a recommended working-set size. [Apple: Metal Compute on MacBook Pro](https://developer.apple.com/videos/play/tech-talks/10580/)

## Why an LLM can overshoot its file size

Weights are only one allocation. There is also a KV cache (the attention state retained for the context), compute scratch space, and runtime overhead. Context length and cache precision affect the KV allocation; batch-related settings affect intermediate buffers. Running concurrent models or requests adds further demand, depending on the runner's sharing behavior. [llama.cpp maintainer explanation](https://github.com/ggml-org/llama.cpp/discussions/9936), [llama-server options](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

Practical inference from that allocation model: if warnings persist during generation, reduce model size or use a smaller quantization, lower context length, reduce concurrency, and close other heavy applications. Compare equivalent runs using a fresh session total. Leave room for the OS and normal applications instead of sizing weights to all installed RAM. A short loading burst and continuous activity throughout generation are different workload patterns; the rolling detector makes that distinction.

## What actually wears an SSD

NAND flash has a finite program/erase budget. Endurance depends on the flash, the controller's wear leveling, and write amplification: internal flash writes can exceed the bytes requested by the host. TBW and DWPD are drive-specific endurance metrics, not general macOS swap limits. Frequent swap writes add to the same write workload as other storage activity. These facts do not establish a failure date or mean occasional swapping is harmful in practice. [Kingston: SSD endurance](https://www.kingston.com/unitedkingdom/en/blog/servers-and-data-centers/understanding-ssd-endurance-tbw-dwpd)

Space reserved for the controller helps garbage collection and can reduce amplification. Filesystem free space is not identical to physical overprovisioning, so the app's low-space indicator is only an operational prompt to preserve headroom, not a measurement of wear. [Kingston: maximizing SSD performance](https://media.kingston.com/images/ssd/enterprise/white_paper/max_ssd_perf_flyer_us.pdf)

The scenario this tool can detect is repeated eviction under a memory-heavy workload: ongoing swap-outs, possibly accompanied by swap-ins and elevated pressure. It cannot detect all SSD wear causes; model downloads, checkpoints, other applications, filesystem metadata, and controller housekeeping are outside its swap counters. It cannot diagnose degradation or report remaining life without separate device telemetry and a drive-specific interpretation.

## Measurements and limitations

| Display | Source | Interpretation |
| --- | --- | --- |
| Pressure | `kern.memorystatus_vm_pressure_level`, with Dispatch pressure-event fallback | Coarse normal/warning/critical state; unknown if neither supplies a value |
| Swap occupancy / allocated | `sysctlbyname("vm.swapusage")` | Current backing-store usage/allocation, not cumulative bytes written |
| Swap read/write rates | `host_statistics64(HOST_VM_INFO64)` counter deltas × `host_page_size` ÷ monotonic elapsed time | Estimated VM swap I/O |
| Compressed / wired memory | Mach VM page counts × host page size | Resident memory context |
| Disk free | Filesystem capacity for the swap volume | Available headroom, not SMART health |
| Session totals | Sum of valid observed counter deltas | App-session exposure, not lifetime SSD writes |

The current open-source XNU swap completion path increments `vm_statistics_swapouts` using the successful compressed segment transfer size divided by page size. Multiplying by the runtime page size therefore estimates compressed swap transfer bytes; it is not the original uncompressed application allocation and should not be multiplied by a compression ratio. OS versions may differ. Neither this count nor filesystem I/O reveals physical NAND writes. [Apple XNU swap completion implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_compressor_backing_store.c)

Generic page-ins are not synonymous with swap-ins: file-backed data also pages in. The implementation uses the dedicated swap counters. The pressure sysctl is treated as a best-effort OS interface; unsupported or denied reads are explicit. Dispatch events provide pressure transitions, so an absent initial event cannot establish normal pressure. [Apple VM statistics documentation](https://developer.apple.com/documentation/kernel/vm_statistics64_data_t), [Apple Dispatch pressure flags](https://developer.apple.com/documentation/dispatch/dispatch_memorypressure_critical)

## Detector policy

The two-second sample interval, 60-second rolling window, 30-second warm-up, 5 MiB/s sustained threshold, and 25% active-time threshold are product choices. They are intentionally adjustable workload signals; no cited source defines them as SSD-safe limits. Rates are averaged over observed elapsed time. Partial intervals at a rolling-window boundary are apportioned uniformly because the counter does not expose individual I/O timestamps. Events shorter than the sample interval cannot be localized more precisely.

Sleep gaps and invalid counters discard the rate baseline. Unavailable data stays unknown rather than becoming a reassuring zero. Measurements remain system-wide: correlate a model run with changes, but do not infer exact process attribution.

## Local observations during development

An initial read on this Mac reported 24 GiB physical memory, normal kernel pressure (level 1), and approximately 4.77 GiB occupied swap. The startup Data volume reported roughly 101.6 GB free. These are point-in-time readings, not a stress test or endurance assessment. `diskutil` also reported SMART “Verified”; that broad status does not reveal a remaining-life percentage and is not used as the app's health indicator.
