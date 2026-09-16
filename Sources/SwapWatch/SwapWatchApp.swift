import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import SwapCore

@main
@MainActor
enum SwapWatchLauncher {
    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            Diagnostics.run()
            return
        }

        if let option = CommandLine.arguments.firstIndex(of: "--screenshot"),
           CommandLine.arguments.indices.contains(option + 1) {
            ScreenshotExporter.run(path: CommandLine.arguments[option + 1])
            return
        }

        SwapWatchApp.main()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var monitor: SwapMonitorModel?
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var updates: AnyCancellable?
    private var currentSymbol: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let monitor = SwapMonitorModel()
        self.monitor = monitor
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        item.button?.target = self
        item.button?.action = #selector(toggleDashboard)
        updates = monitor.$summary.sink { [weak self] summary in
            // @Published emits before assignment; defer reading related fields.
            DispatchQueue.main.async { self?.updateStatus(summary: summary) }
        }
        updateStatus(summary: nil)
        if CommandLine.arguments.contains("--verify-ui-lifecycle") {
            verifyUILifecycle()
        }
    }

    private func updateStatus(summary: MonitorSummary?) {
        guard let monitor, let button = item?.button else { return }
        let pressure = monitor.effectivePressure
        let warning = [.frequent, .sustained, .churning].contains(summary?.activity ?? .unknown)
        let symbol = warning && (pressure == .normal || pressure == .unknown)
            ? "exclamationmark.triangle.fill" : pressure.symbolName
        if currentSymbol != symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: pressure.displayName)
            button.imagePosition = .imageLeading
            currentSymbol = symbol
        }
        let title = " \(pressure.menuName) · \(DisplayFormat.compactBytes(monitor.snapshot?.swapUsedBytes)) · \(DisplayFormat.compactRate(summary?.currentWriteBytesPerSecond))"
        if button.title != title { button.title = title }
        button.toolTip = "\(pressure.displayName) · \(summary?.activity.displayName ?? "Collecting activity") · swap used · swap write rate"
    }

    @objc private func toggleDashboard() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let monitor, let button = item?.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 390, height: 620)
        popover.contentViewController = NSHostingController(rootView: DashboardView(monitor: monitor))
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        // Release the view graph, scroll view, and drawing surfaces when idle.
        popover?.contentViewController = nil
        popover = nil
    }

    /// Explicit diagnostic mode exercises real open/close cycles without
    /// Accessibility permission. It never changes notification preferences.
    private func verifyUILifecycle() {
        for step in 0...6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step * 3 + 3)) { [weak self] in
                guard let self else { return }
                if step > 0 { self.toggleDashboard() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    var info = task_vm_info_data_t()
                    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                    let result = withUnsafeMutablePointer(to: &info) { pointer in
                        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                        }
                    }
                    if result == KERN_SUCCESS {
                        print("\(step == 0 ? "idle" : step % 2 == 1 ? "open" : "closed") footprint MiB: \(Double(info.phys_footprint) / 1_048_576)")
                        fflush(stdout)
                    }
                    if step == 6 { NSApplication.shared.terminate(nil) }
                }
            }
        }
    }
}

@MainActor
struct SwapWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

private enum Diagnostics {
    static func run() {
        let sampler = SystemSampler()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        for index in 0..<3 {
            do {
                let sample = try sampler.sample()
                let record = DiagnosticRecord(sample: sample)
                let data = try encoder.encode(record)
                if let line = String(data: data, encoding: .utf8) {
                    print(line)
                }
            } catch {
                let failure = DiagnosticFailure(error: String(describing: error))
                if let data = try? encoder.encode(failure),
                   let line = String(data: data, encoding: .utf8) {
                    print(line)
                }
            }

            if index < 2 {
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    private struct DiagnosticRecord: Encodable {
        let timestamp: Date
        let uptime: TimeInterval
        let pageSize: UInt64
        let swapIns: UInt64
        let swapOuts: UInt64
        let swapUsedBytes: UInt64?
        let swapAllocatedBytes: UInt64?
        let physicalMemoryBytes: UInt64
        let compressedBytes: UInt64
        let wiredBytes: UInt64
        let diskFreeBytes: UInt64?
        let diskTotalBytes: UInt64?
        let pressure: String
        let issues: [String]

        init(sample: MemorySnapshot) {
            timestamp = sample.timestamp
            uptime = sample.uptime
            pageSize = sample.pageSize
            swapIns = sample.swapIns
            swapOuts = sample.swapOuts
            swapUsedBytes = sample.swapUsedBytes
            swapAllocatedBytes = sample.swapAllocatedBytes
            physicalMemoryBytes = sample.physicalMemoryBytes
            compressedBytes = sample.compressedBytes
            wiredBytes = sample.wiredBytes
            diskFreeBytes = sample.diskFreeBytes
            diskTotalBytes = sample.diskTotalBytes
            pressure = sample.pressure.rawValue
            issues = sample.issues
        }
    }

    private struct DiagnosticFailure: Encodable {
        let timestamp = Date()
        let error: String
    }
}

@MainActor
private enum ScreenshotExporter {
    static func run(path: String) {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let monitor = SwapMonitorModel()
        monitor.start()
        RunLoop.current.run(until: Date().addingTimeInterval(4.25))

        let hostingView = NSHostingView(rootView: DashboardView(monitor: monitor))
        hostingView.frame = NSRect(x: 0, y: 0, width: 390, height: 620)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            fputs("SwapWatch: could not create screenshot bitmap.\n", stderr)
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fputs("SwapWatch: could not encode screenshot as PNG.\n", stderr)
            return
        }

        do {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            print(path)
        } catch {
            fputs("SwapWatch: \(error.localizedDescription)\n", stderr)
        }
    }
}
