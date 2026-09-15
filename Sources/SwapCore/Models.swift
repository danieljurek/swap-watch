import Foundation

/// The kernel's current memory-pressure assessment.
public enum MemoryPressure: String, Sendable {
    case unknown
    case normal
    case warning
    case critical
}

/// A point-in-time view of the system metrics used by ``SwapAnalyzer``.
public struct MemorySnapshot: Sendable {
    public let timestamp: Date
    public let uptime: TimeInterval
    public let pageSize: UInt64
    public let swapIns: UInt64
    public let swapOuts: UInt64
    public let swapUsedBytes: UInt64?
    public let swapAllocatedBytes: UInt64?
    public let physicalMemoryBytes: UInt64
    public let compressedBytes: UInt64
    public let wiredBytes: UInt64

    /// Free bytes on the filesystem that contains macOS swap files.
    ///
    /// This is volume-level capacity, not a quota reserved for swap. On a
    /// standard macOS installation it describes the Data volume containing
    /// `/private/var/vm`.
    public let diskFreeBytes: UInt64?

    /// Total bytes on the filesystem described by ``diskFreeBytes``.
    public let diskTotalBytes: UInt64?
    public let pressure: MemoryPressure

    /// Non-fatal collection failures for optional metrics.
    public let issues: [String]

    public init(
        timestamp: Date,
        uptime: TimeInterval,
        pageSize: UInt64,
        swapIns: UInt64,
        swapOuts: UInt64,
        swapUsedBytes: UInt64?,
        swapAllocatedBytes: UInt64?,
        physicalMemoryBytes: UInt64,
        compressedBytes: UInt64,
        wiredBytes: UInt64,
        diskFreeBytes: UInt64?,
        diskTotalBytes: UInt64?,
        pressure: MemoryPressure,
        issues: [String]
    ) {
        self.timestamp = timestamp
        self.uptime = uptime
        self.pageSize = pageSize
        self.swapIns = swapIns
        self.swapOuts = swapOuts
        self.swapUsedBytes = swapUsedBytes
        self.swapAllocatedBytes = swapAllocatedBytes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.compressedBytes = compressedBytes
        self.wiredBytes = wiredBytes
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
        self.pressure = pressure
        self.issues = issues
    }
}

public struct MonitorThresholds: Sendable {
    public var sustainedMiBPerSecond: Double
    public var frequentWriteFraction: Double
    public var activeMiBPerSecond: Double

    public init(
        sustainedMiBPerSecond: Double = 5,
        frequentWriteFraction: Double = 0.25,
        activeMiBPerSecond: Double = 1
    ) {
        self.sustainedMiBPerSecond = sustainedMiBPerSecond
        self.frequentWriteFraction = frequentWriteFraction
        self.activeMiBPerSecond = activeMiBPerSecond
    }
}

public enum ActivityLevel: String, Sendable {
    case unknown
    case idle
    case writing
    case frequent
    case sustained
    case churning
}

public struct ActivityPoint: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let writeBytesPerSecond: Double
    public let readBytesPerSecond: Double

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        writeBytesPerSecond: Double,
        readBytesPerSecond: Double
    ) {
        self.id = id
        self.timestamp = timestamp
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readBytesPerSecond = readBytesPerSecond
    }
}

public struct MonitorSummary: Sendable {
    public let currentWriteBytesPerSecond: Double?
    public let currentReadBytesPerSecond: Double?
    public let averageWriteBytesPerSecond: Double?
    public let writeActiveFraction: Double?
    public let observedSeconds: TimeInterval
    public let sessionWriteBytes: Double
    public let sessionReadBytes: Double
    public let activity: ActivityLevel
    public let history: [ActivityPoint]
    public let note: String

    public init(
        currentWriteBytesPerSecond: Double?,
        currentReadBytesPerSecond: Double?,
        averageWriteBytesPerSecond: Double?,
        writeActiveFraction: Double?,
        observedSeconds: TimeInterval,
        sessionWriteBytes: Double,
        sessionReadBytes: Double,
        activity: ActivityLevel,
        history: [ActivityPoint],
        note: String
    ) {
        self.currentWriteBytesPerSecond = currentWriteBytesPerSecond
        self.currentReadBytesPerSecond = currentReadBytesPerSecond
        self.averageWriteBytesPerSecond = averageWriteBytesPerSecond
        self.writeActiveFraction = writeActiveFraction
        self.observedSeconds = observedSeconds
        self.sessionWriteBytes = sessionWriteBytes
        self.sessionReadBytes = sessionReadBytes
        self.activity = activity
        self.history = history
        self.note = note
    }
}
