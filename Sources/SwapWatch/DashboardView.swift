import AppKit
import Foundation
import SwapCore
import SwiftUI

struct MenuBarStatusLabel: View {
    @ObservedObject var monitor: SwapMonitorModel

    var body: some View {
        let pressure = monitor.effectivePressure
        HStack(spacing: 4) {
            Image(systemName: menuSymbol)
            Text("\(pressure.menuName) · \(DisplayFormat.compactBytes(monitor.snapshot?.swapUsedBytes)) · \(DisplayFormat.compactRate(monitor.summary?.currentWriteBytesPerSecond))")
        }
        .help(menuHelp)
    }

    private var hasActivityWarning: Bool {
        switch monitor.summary?.activity {
        case .frequent, .sustained, .churning: return true
        default: return false
        }
    }

    private var menuSymbol: String {
        if monitor.effectivePressure == .normal || monitor.effectivePressure == .unknown,
           hasActivityWarning {
            return "exclamationmark.triangle.fill"
        }
        return monitor.effectivePressure.symbolName
    }

    private var menuHelp: String {
        var status = "Memory \(monitor.effectivePressure.displayName.lowercased())"
        if hasActivityWarning, let activity = monitor.summary?.activity {
            status += " · \(activity.displayName)"
        }
        return "\(status) · swap used · swap write rate"
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: SwapMonitorModel
    @AppStorage(PreferenceKeys.sustainedRate) private var sustainedRate = 5.0
    @AppStorage(PreferenceKeys.frequentFraction) private var frequentFraction = 0.25
    @State private var showsSettings = false

    private let grid = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if let warning = warningMessage {
                    WarningBanner(message: warning.message, color: warning.color)
                }

                if let diskWarning = lowDiskWarning {
                    WarningBanner(message: diskWarning, color: .orange)
                }

                if let error = monitor.samplingError {
                    UnavailableBanner(message: error)
                } else if let issues = monitor.snapshot?.issues, !issues.isEmpty {
                    UnavailableBanner(message: issues.joined(separator: " · "))
                }

                occupancySection
                ioSection
                sparklineSection
                memorySection
                sessionSection
                settingsSection
                footer
            }
            .padding(16)
        }
        .frame(width: 390, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            monitor.start()
            monitor.updateThresholds(sustainedRate: sustainedRate, frequentFraction: frequentFraction)
            await monitor.notifications.refresh()
        }
        .onChange(of: sustainedRate) { value in
            monitor.updateThresholds(sustainedRate: value, frequentFraction: frequentFraction)
        }
        .onChange(of: frequentFraction) { value in
            monitor.updateThresholds(sustainedRate: sustainedRate, frequentFraction: value)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SwapWatch")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(liveStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                StatusPill(
                    title: monitor.effectivePressure.displayName,
                    symbol: monitor.effectivePressure.symbolName,
                    color: monitor.effectivePressure.color
                )
                StatusPill(
                    title: activityLabel,
                    symbol: "arrow.left.arrow.right",
                    color: monitor.summary?.activity.color ?? .secondary
                )
                Spacer(minLength: 0)
            }
        }
    }

    private var occupancySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Swap occupancy")
            LazyVGrid(columns: grid, spacing: 10) {
                MetricTile(title: "Swap used", value: DisplayFormat.bytes(monitor.snapshot?.swapUsedBytes))
                MetricTile(title: "Swap allocated", value: DisplayFormat.bytes(monitor.snapshot?.swapAllocatedBytes))
            }
            Text("Allocated is current swap backing, not a fixed capacity limit.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var ioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Swap I/O")
                Spacer()
                Text(windowStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: grid, spacing: 10) {
                MetricTile(title: "Write rate", value: DisplayFormat.rate(monitor.summary?.currentWriteBytesPerSecond), accent: .orange)
                MetricTile(title: "Read rate", value: DisplayFormat.rate(monitor.summary?.currentReadBytesPerSecond), accent: .blue)
                MetricTile(title: "60s avg write", value: DisplayFormat.rate(warmedUp ? monitor.summary?.averageWriteBytesPerSecond : nil))
                MetricTile(title: "60s write duty", value: DisplayFormat.percent(warmedUp ? monitor.summary?.writeActiveFraction : nil))
            }
            if let note = monitor.summary?.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sparklineSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionTitle("Last 10 minutes")
                Spacer()
                LegendDot(color: .orange, label: "Write")
                LegendDot(color: .blue, label: "Read")
            }

            if let history = monitor.summary?.history, history.count >= 2 {
                SwapSparkline(points: history, threshold: sustainedRate)
                .frame(height: 86)
                .accessibilityLabel("Swap read and write rates over the last ten minutes")
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 86)
                    .overlay {
                        Text(monitor.samplingError == nil ? "Collecting history…" : "History unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Memory & storage")
            LazyVGrid(columns: grid, spacing: 10) {
                MetricTile(title: "Compressed", value: DisplayFormat.bytes(monitor.snapshot?.compressedBytes))
                MetricTile(title: "Wired", value: DisplayFormat.bytes(monitor.snapshot?.wiredBytes))
                MetricTile(title: "Physical memory", value: DisplayFormat.bytes(monitor.snapshot?.physicalMemoryBytes))
                MetricTile(title: "Disk free", value: diskFreeText)
            }
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("This monitoring session")
                Spacer()
                Button("Reset") { monitor.resetSession() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            LazyVGrid(columns: grid, spacing: 10) {
                MetricTile(title: "Est. swap writes", value: DisplayFormat.estimatedBytes(monitor.summary?.sessionWriteBytes), accent: .orange)
                MetricTile(title: "Est. swap reads", value: DisplayFormat.estimatedBytes(monitor.summary?.sessionReadBytes), accent: .blue)
            }
            Text("Derived from OS swap counters; this is estimated swap I/O, not physical NAND writes or SSD lifespan.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var settingsSection: some View {
        DisclosureGroup("Alerts & thresholds", isExpanded: $showsSettings) {
            VStack(alignment: .leading, spacing: 10) {
                Stepper(value: $sustainedRate, in: 0.5...100, step: 0.5) {
                    HStack {
                        Text("Sustained rate")
                        Spacer()
                        Text(String(format: "%.1f MiB/s", sustainedRate))
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $frequentFraction, in: 0.05...1, step: 0.05) {
                    HStack {
                        Text("Frequent-write duty")
                        Spacer()
                        Text(DisplayFormat.percent(frequentFraction))
                            .foregroundStyle(.secondary)
                    }
                }
                NotificationSettingsView(permissions: monitor.notifications)
            }
            .font(.caption)
            .padding(.top, 8)
        }
        .font(.caption.weight(.medium))
        .disclosureGroupStyle(ClickableDisclosureStyle())
    }

    private var footer: some View {
        HStack {
            Button("Activity Monitor") { monitor.openActivityMonitor() }
            Spacer()
            Button("Quit SwapWatch") { NSApplication.shared.terminate(nil) }
        }
        .controlSize(.small)
    }

    private var warmedUp: Bool {
        (monitor.summary?.observedSeconds ?? 0) >= 30
    }

    private var windowStatus: String {
        guard let summary = monitor.summary else { return "Unavailable" }
        if summary.observedSeconds < 30 {
            return "Warming up · \(DisplayFormat.duration(summary.observedSeconds))/30s"
        }
        return "60s window"
    }

    private var activityLabel: String {
        guard let summary = monitor.summary else {
            return monitor.samplingError == nil ? "Activity warming up" : "Activity unavailable"
        }
        if summary.observedSeconds < 2 { return "Activity warming up" }
        return summary.activity.displayName
    }

    private var diskFreeText: String {
        guard let snapshot = monitor.snapshot else { return "—" }
        if let total = snapshot.diskTotalBytes, let free = snapshot.diskFreeBytes {
            return "\(DisplayFormat.bytes(free)) of \(DisplayFormat.bytes(total))"
        }
        return DisplayFormat.bytes(snapshot.diskFreeBytes)
    }

    private var liveStatus: String {
        if monitor.samplingError != nil {
            if let lastSample = monitor.lastSuccessfulSampleAt {
                return "Unavailable · last \(lastSample.formatted(date: .omitted, time: .shortened))"
            }
            return "Unavailable"
        }
        return monitor.snapshot == nil ? "Starting…" : "Live · 2s"
    }

    private var lowDiskWarning: String? {
        guard let free = monitor.snapshot?.diskFreeBytes else { return nil }
        let fewerThanTenGiB = free < 10 * 1_073_741_824
        let fewerThanTenPercent: Bool
        if let total = monitor.snapshot?.diskTotalBytes, total > 0 {
            fewerThanTenPercent = Double(free) / Double(total) < 0.10
        } else {
            fewerThanTenPercent = false
        }
        guard fewerThanTenGiB || fewerThanTenPercent else { return nil }
        return "Low disk headroom heuristic: \(DisplayFormat.bytes(free)) free on the swap volume. Free space is not an SSD-wear measurement."
    }

    private var warningMessage: (message: String, color: Color)? {
        switch monitor.effectivePressure {
        case .critical:
            return ("Critical memory pressure. Save work and close or pause memory-heavy apps.", .red)
        case .warning:
            return ("Memory pressure is elevated. Check Activity Monitor and close memory-heavy apps if responsiveness drops.", .orange)
        case .unknown, .normal:
            break
        }

        switch monitor.summary?.activity {
        case .churning, .sustained:
            return ("Sustained swap I/O is increasing SSD traffic. Pause or quit memory-heavy apps if this continues.", .orange)
        case .frequent:
            return ("Swap writes are frequent. Check Activity Monitor for apps using unusually large amounts of memory.", .yellow)
        default:
            return nil
        }
    }
}

/// One button owns the complete header hit area, so the arrow and label
/// toggle exactly once and share keyboard/accessibility behavior.
private struct ClickableDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private struct SectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    var accent: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusPill: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct WarningBanner: View {
    let message: String
    let color: Color

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct UnavailableBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}
