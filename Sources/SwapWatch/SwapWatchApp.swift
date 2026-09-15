import AppKit
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
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@MainActor
struct SwapWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = SwapMonitorModel()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(monitor: monitor)
        } label: {
            MenuBarStatusLabel(monitor: monitor)
                .task { monitor.start() }
        }
        .menuBarExtraStyle(.window)
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
        RunLoop.current.run(until: Date().addingTimeInterval(2.25))

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
