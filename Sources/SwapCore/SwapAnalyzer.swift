import Foundation

/// Converts lifetime page counters into interval rates and rolling activity.
///
/// The kernel counters describe pages moved to and from compressed swap
/// segments. Multiplying their deltas by the host page size estimates swap I/O;
/// it is not a measurement of physical NAND writes (filesystem and device
/// behavior can make those differ).
public struct SwapAnalyzer: Sendable {
    private struct RateInterval: Sendable {
        let startUptime: TimeInterval
        let endUptime: TimeInterval
        let writeBytesPerSecond: Double
        let readBytesPerSecond: Double
    }

    private struct HistoryRecord: Sendable {
        let uptime: TimeInterval
        let point: ActivityPoint
    }

    private var baseline: MemorySnapshot?
    private var intervals: [RateInterval] = []
    private var historyRecords: [HistoryRecord] = []
    private var sessionWriteBytes = 0.0
    private var sessionReadBytes = 0.0

    private static let analysisWindow: TimeInterval = 60
    private static let historyWindow: TimeInterval = 10 * 60
    private static let maximumSampleGap: TimeInterval = 10
    private static let minimumClassificationObservation: TimeInterval = 30
    private static let bytesPerMiB = 1_048_576.0

    public init() {}

    public mutating func ingest(
        _ snapshot: MemorySnapshot,
        thresholds: MonitorThresholds = .init()
    ) -> MonitorSummary {
        pruneHistory(now: snapshot.uptime)

        guard let previous = baseline else {
            baseline = snapshot
            intervals.removeAll(keepingCapacity: true)
            return emptySummary(
                note: "Collecting a baseline. Lifetime swap counters are not charged to this session."
            )
        }

        let elapsed = snapshot.uptime - previous.uptime
        guard elapsed.isFinite,
              elapsed > 0,
              elapsed <= Self.maximumSampleGap,
              snapshot.pageSize > 0,
              snapshot.pageSize == previous.pageSize,
              snapshot.swapOuts >= previous.swapOuts,
              snapshot.swapIns >= previous.swapIns else {
            baseline = snapshot
            intervals.removeAll(keepingCapacity: true)
            return emptySummary(
                note: "The sampling interval changed or counters reset. A fresh baseline is being collected; no I/O was inferred for the gap."
            )
        }

        // Convert in floating point so a large page delta cannot overflow an
        // integer multiplication before conversion.
        let writeBytes = Double(snapshot.swapOuts - previous.swapOuts) * Double(snapshot.pageSize)
        let readBytes = Double(snapshot.swapIns - previous.swapIns) * Double(snapshot.pageSize)
        let writeRate = writeBytes / elapsed
        let readRate = readBytes / elapsed

        guard writeBytes.isFinite,
              readBytes.isFinite,
              writeRate.isFinite,
              readRate.isFinite else {
            baseline = snapshot
            intervals.removeAll(keepingCapacity: true)
            return emptySummary(
                note: "The counter delta was outside the measurable range. A fresh baseline is being collected."
            )
        }

        baseline = snapshot
        sessionWriteBytes += writeBytes
        sessionReadBytes += readBytes

        intervals.append(
            RateInterval(
                startUptime: previous.uptime,
                endUptime: snapshot.uptime,
                writeBytesPerSecond: writeRate,
                readBytesPerSecond: readRate
            )
        )
        pruneIntervals(now: snapshot.uptime)

        historyRecords.append(
            HistoryRecord(
                uptime: snapshot.uptime,
                point: ActivityPoint(
                    timestamp: snapshot.timestamp,
                    writeBytesPerSecond: writeRate,
                    readBytesPerSecond: readRate
                )
            )
        )
        pruneHistory(now: snapshot.uptime)

        return makeSummary(
            now: snapshot.uptime,
            currentWrite: writeRate,
            currentRead: readRate,
            thresholds: thresholds
        )
    }

    /// Clears all observations, including the session byte totals.
    public mutating func reset() {
        baseline = nil
        intervals.removeAll(keepingCapacity: false)
        historyRecords.removeAll(keepingCapacity: false)
        sessionWriteBytes = 0
        sessionReadBytes = 0
    }

    /// Invalidates rate calculations while preserving the session totals and
    /// chart history accumulated so far.
    public mutating func invalidate() {
        baseline = nil
        intervals.removeAll(keepingCapacity: true)
    }
}

private extension SwapAnalyzer {
    mutating func pruneIntervals(now: TimeInterval) {
        let cutoff = now - Self.analysisWindow
        intervals.removeAll { $0.endUptime <= cutoff }
    }

    mutating func pruneHistory(now: TimeInterval) {
        guard now.isFinite else {
            historyRecords.removeAll(keepingCapacity: true)
            return
        }
        let cutoff = now - Self.historyWindow
        historyRecords.removeAll { $0.uptime < cutoff || $0.uptime > now }
    }

    func makeSummary(
        now: TimeInterval,
        currentWrite: Double,
        currentRead: Double,
        thresholds: MonitorThresholds
    ) -> MonitorSummary {
        let cutoff = now - Self.analysisWindow
        let activeRate = normalizedPositive(
            thresholds.activeMiBPerSecond,
            fallback: MonitorThresholds().activeMiBPerSecond
        ) * Self.bytesPerMiB
        let sustainedRate = normalizedPositive(
            thresholds.sustainedMiBPerSecond,
            fallback: MonitorThresholds().sustainedMiBPerSecond
        ) * Self.bytesPerMiB
        let frequentFraction = normalizedFraction(
            thresholds.frequentWriteFraction,
            fallback: MonitorThresholds().frequentWriteFraction
        )

        var observed = 0.0
        var writeBytes = 0.0
        var readBytes = 0.0
        var writeActiveSeconds = 0.0

        // Samples represent an average rate over the interval since the prior
        // sample. When the 60-second boundary cuts an interval, that rate is
        // assumed uniform and weighted only by the portion inside the window.
        for interval in intervals {
            let start = max(interval.startUptime, cutoff)
            let end = min(interval.endUptime, now)
            let duration = max(0, end - start)
            guard duration > 0 else { continue }

            observed += duration
            writeBytes += interval.writeBytesPerSecond * duration
            readBytes += interval.readBytesPerSecond * duration
            if interval.writeBytesPerSecond >= activeRate {
                writeActiveSeconds += duration
            }
        }

        let averageWrite = observed > 0 ? writeBytes / observed : nil
        let averageRead = observed > 0 ? readBytes / observed : nil
        let activeFraction = observed > 0 ? writeActiveSeconds / observed : nil
        let warmedUp = observed >= Self.minimumClassificationObservation

        let hasSustainedWrites = warmedUp && (averageWrite ?? 0) >= sustainedRate
        let hasFrequentWrites = warmedUp && (activeFraction ?? 0) >= frequentFraction
        let hasSubstantialReads = (averageRead ?? 0) >= activeRate

        let activity: ActivityLevel
        if (hasSustainedWrites || hasFrequentWrites) && hasSubstantialReads {
            activity = .churning
        } else if hasSustainedWrites {
            activity = .sustained
        } else if hasFrequentWrites {
            activity = .frequent
        } else if currentWrite > 0 {
            activity = .writing
        } else {
            activity = .idle
        }

        return MonitorSummary(
            currentWriteBytesPerSecond: currentWrite,
            currentReadBytesPerSecond: currentRead,
            averageWriteBytesPerSecond: averageWrite,
            writeActiveFraction: activeFraction,
            observedSeconds: observed,
            sessionWriteBytes: sessionWriteBytes,
            sessionReadBytes: sessionReadBytes,
            activity: activity,
            history: historyRecords.map(\.point),
            note: note(
                for: activity,
                observed: observed,
                averageWrite: averageWrite,
                activeFraction: activeFraction,
                warmedUp: warmedUp
            )
        )
    }

    func emptySummary(note: String) -> MonitorSummary {
        MonitorSummary(
            currentWriteBytesPerSecond: nil,
            currentReadBytesPerSecond: nil,
            averageWriteBytesPerSecond: nil,
            writeActiveFraction: nil,
            observedSeconds: 0,
            sessionWriteBytes: sessionWriteBytes,
            sessionReadBytes: sessionReadBytes,
            activity: .unknown,
            history: historyRecords.map(\.point),
            note: note
        )
    }

    func note(
        for activity: ActivityLevel,
        observed: TimeInterval,
        averageWrite: Double?,
        activeFraction: Double?,
        warmedUp: Bool
    ) -> String {
        if !warmedUp {
            let remaining = max(0, Self.minimumClassificationObservation - observed)
            return "Warming up for \(Int(ceil(remaining))) more seconds before classifying frequent or sustained swap activity."
        }

        let averageMiB = (averageWrite ?? 0) / Self.bytesPerMiB
        let activePercent = (activeFraction ?? 0) * 100
        switch activity {
        case .unknown:
            return "Collecting enough information to estimate swap activity."
        case .idle:
            return "No swap writes occurred in the latest interval. The rolling average is \(formatted(averageMiB)) MiB/s."
        case .writing:
            return "Swap is writing now, but the 60-second pattern is below the frequent and sustained thresholds."
        case .frequent:
            return "Swap writes were active for \(formatted(activePercent))% of the observed window. Reduce memory demand if this persists."
        case .sustained:
            return "Swap writes averaged \(formatted(averageMiB)) MiB/s. Closing memory-heavy work can reduce sustained I/O."
        case .churning:
            return "Sustained or frequent swap writes are accompanied by substantial reads. The system may be repeatedly evicting and restoring memory."
        }
    }

    func normalizedPositive(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }

    func normalizedFraction(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value > 0 && value <= 1 ? value : fallback
    }

    func formatted(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
