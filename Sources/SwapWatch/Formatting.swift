import Foundation
import SwapCore
import SwiftUI

enum DisplayFormat {
    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.isAdaptive = true
        formatter.includesUnit = true
        return formatter
    }()

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return bytesFormatter.string(fromByteCount: clampedInt64(value))
    }

    static func estimatedBytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return bytesFormatter.string(fromByteCount: clampedInt64(value))
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond, value.isFinite, value >= 0 else { return "—" }
        if value == 0 { return "0 B/s" }
        if value < 1 { return "<1 B/s" }
        if value < 1_024 { return String(format: "%.0f B/s", value) }
        if value < 1_048_576 { return String(format: "%.1f KiB/s", value / 1_024) }
        if value < 1_073_741_824 { return String(format: "%.1f MiB/s", value / 1_048_576) }
        return String(format: "%.2f GiB/s", value / 1_073_741_824)
    }

    static func compactBytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        if value < 1_048_576 { return "<1M" }
        if value < 1_073_741_824 { return String(format: "%.0fM", Double(value) / 1_048_576) }
        return String(format: "%.1fG", Double(value) / 1_073_741_824)
    }

    static func compactRate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value == 0 { return "0B/s" }
        if value < 1 { return "<1B/s" }
        if value < 1_024 { return String(format: "%.0fB/s", value) }
        if value < 1_048_576 { return String(format: "%.0fKiB/s", value / 1_024) }
        if value < 1_073_741_824 { return String(format: "%.1fMiB/s", value / 1_048_576) }
        return String(format: "%.1fGiB/s", value / 1_073_741_824)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f%%", min(max(value, 0), 1) * 100)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }

    private static func clampedInt64(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    private static func clampedInt64(_ value: Double) -> Int64 {
        value >= Double(Int64.max) ? Int64.max : Int64(value)
    }
}

extension MemoryPressure {
    var displayName: String {
        switch self {
        case .unknown: return "Pressure unknown"
        case .normal: return "Pressure normal"
        case .warning: return "Pressure warning"
        case .critical: return "Pressure critical"
        }
    }

    var menuName: String {
        switch self {
        case .unknown: return "Unknown"
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return .secondary
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}

extension ActivityLevel {
    var displayName: String {
        switch self {
        case .unknown: return "Activity unavailable"
        case .idle: return "Swap writes idle"
        case .writing: return "Swap writes active"
        case .frequent: return "Writes frequent"
        case .sustained: return "Sustained writes"
        case .churning: return "Swap churn"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return .secondary
        case .idle: return .secondary
        case .writing: return .blue
        case .frequent: return .yellow
        case .sustained: return .orange
        case .churning: return .red
        }
    }
}
