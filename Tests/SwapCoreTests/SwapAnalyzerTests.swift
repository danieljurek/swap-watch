import XCTest
@testable import SwapCore

final class SwapAnalyzerTests: XCTestCase {
    private let mib = 1_048_576.0

    func testFirstSampleHasUnknownRatesAndSwapOccupancyDoesNotCountAsActivity() {
        var analyzer = SwapAnalyzer()

        let result = analyzer.ingest(snapshot(
            uptime: 100,
            swapIns: 20,
            swapOuts: 40,
            swapUsedBytes: 12 * 1_048_576,
            swapAllocatedBytes: 16 * 1_048_576
        ))

        XCTAssertNil(result.currentWriteBytesPerSecond)
        XCTAssertNil(result.currentReadBytesPerSecond)
        XCTAssertNil(result.averageWriteBytesPerSecond)
        XCTAssertNil(result.writeActiveFraction)
        XCTAssertEqual(result.observedSeconds, 0)
        XCTAssertEqual(result.sessionWriteBytes, 0)
        XCTAssertEqual(result.sessionReadBytes, 0)
        XCTAssertEqual(result.activity, .unknown)
    }

    func testRatesUseFourKiBHostPageSizeAndCounterDirection() throws {
        var analyzer = SwapAnalyzer()
        _ = analyzer.ingest(snapshot(uptime: 10, pageSize: 4_096, swapIns: 100, swapOuts: 200))

        let result = analyzer.ingest(snapshot(uptime: 12, pageSize: 4_096, swapIns: 356, swapOuts: 712))

        XCTAssertEqual(try XCTUnwrap(result.currentReadBytesPerSecond), 512 * 1_024, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(result.currentWriteBytesPerSecond), 1_024 * 1_024, accuracy: 0.01)
        XCTAssertEqual(result.sessionReadBytes, 1_024 * 1_024, accuracy: 0.01)
        XCTAssertEqual(result.sessionWriteBytes, 2 * 1_024 * 1_024, accuracy: 0.01)
    }

    func testRatesUseSixteenKiBHostPageSize() throws {
        var analyzer = SwapAnalyzer()
        _ = analyzer.ingest(snapshot(uptime: 10, pageSize: 16_384, swapIns: 0, swapOuts: 0))

        let result = analyzer.ingest(snapshot(uptime: 12, pageSize: 16_384, swapIns: 64, swapOuts: 128))

        XCTAssertEqual(try XCTUnwrap(result.currentReadBytesPerSecond), 512 * 1_024, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(result.currentWriteBytesPerSecond), 1_024 * 1_024, accuracy: 0.01)
    }

    func testSessionTotalsAccumulateOnlyValidCounterDeltas() {
        var analyzer = SwapAnalyzer()
        _ = analyzer.ingest(snapshot(uptime: 0, swapIns: 10, swapOuts: 20))
        _ = analyzer.ingest(snapshot(uptime: 2, swapIns: 30, swapOuts: 60))
        let result = analyzer.ingest(snapshot(uptime: 4, swapIns: 35, swapOuts: 70))

        XCTAssertEqual(result.sessionReadBytes, 25 * 4_096, accuracy: 0.01)
        XCTAssertEqual(result.sessionWriteBytes, 50 * 4_096, accuracy: 0.01)
    }

    func testCounterRegressionResetsBaselineWithoutChargingTheInterval() throws {
        var analyzer = SwapAnalyzer()
        _ = analyzer.ingest(snapshot(uptime: 0, swapIns: 100, swapOuts: 100))
        _ = analyzer.ingest(snapshot(uptime: 2, swapIns: 110, swapOuts: 120))

        let regressed = analyzer.ingest(snapshot(uptime: 4, swapIns: 2, swapOuts: 3))
        XCTAssertNil(regressed.currentReadBytesPerSecond)
        XCTAssertNil(regressed.currentWriteBytesPerSecond)
        XCTAssertEqual(regressed.sessionReadBytes, 10 * 4_096, accuracy: 0.01)
        XCTAssertEqual(regressed.sessionWriteBytes, 20 * 4_096, accuracy: 0.01)

        let resumed = analyzer.ingest(snapshot(uptime: 6, swapIns: 6, swapOuts: 11))
        XCTAssertEqual(try XCTUnwrap(resumed.currentReadBytesPerSecond), 2 * 4_096, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(resumed.currentWriteBytesPerSecond), 4 * 4_096, accuracy: 0.01)
        XCTAssertEqual(resumed.sessionReadBytes, 14 * 4_096, accuracy: 0.01)
        XCTAssertEqual(resumed.sessionWriteBytes, 28 * 4_096, accuracy: 0.01)
    }

    func testLongGapResetsBaselineAndWindowWithoutChargingGap() throws {
        var analyzer = SwapAnalyzer()
        _ = analyzer.ingest(snapshot(uptime: 0, swapOuts: 0))
        _ = analyzer.ingest(snapshot(uptime: 2, swapOuts: 100))

        let afterGap = analyzer.ingest(snapshot(uptime: 13, swapOuts: 10_000))
        XCTAssertNil(afterGap.currentWriteBytesPerSecond)
        XCTAssertNil(afterGap.averageWriteBytesPerSecond)
        XCTAssertEqual(afterGap.observedSeconds, 0)
        XCTAssertEqual(afterGap.sessionWriteBytes, 100 * 4_096, accuracy: 0.01)

        let resumed = analyzer.ingest(snapshot(uptime: 15, swapOuts: 10_010))
        XCTAssertEqual(try XCTUnwrap(resumed.currentWriteBytesPerSecond), 5 * 4_096, accuracy: 0.01)
        XCTAssertEqual(resumed.observedSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(resumed.sessionWriteBytes, 110 * 4_096, accuracy: 0.01)
    }

    func testZeroUptimeDeltaResetsBaselineWithoutChargingCounters() throws {
        var analyzer = SwapAnalyzer()
        _ = analyzer.ingest(snapshot(uptime: 20, swapOuts: 100))

        let invalid = analyzer.ingest(snapshot(uptime: 20, swapOuts: 500))
        XCTAssertNil(invalid.currentWriteBytesPerSecond)
        XCTAssertEqual(invalid.sessionWriteBytes, 0)

        let resumed = analyzer.ingest(snapshot(uptime: 22, swapOuts: 504))
        XCTAssertEqual(try XCTUnwrap(resumed.currentWriteBytesPerSecond), 2 * 4_096, accuracy: 0.01)
        XCTAssertEqual(resumed.sessionWriteBytes, 4 * 4_096, accuracy: 0.01)
    }

    func testPageSizeChangeResetsBaselineAndWindowWithoutChargingCounters() throws {
        var analyzer = SwapAnalyzer()
        _ = analyzer.ingest(snapshot(uptime: 0, pageSize: 4_096, swapOuts: 100))
        _ = analyzer.ingest(snapshot(uptime: 2, pageSize: 4_096, swapOuts: 110))

        let changed = analyzer.ingest(snapshot(uptime: 4, pageSize: 16_384, swapOuts: 1_000))
        XCTAssertNil(changed.currentWriteBytesPerSecond)
        XCTAssertNil(changed.averageWriteBytesPerSecond)
        XCTAssertEqual(changed.sessionWriteBytes, 10 * 4_096, accuracy: 0.01)

        let resumed = analyzer.ingest(snapshot(uptime: 6, pageSize: 16_384, swapOuts: 1_002))
        XCTAssertEqual(try XCTUnwrap(resumed.currentWriteBytesPerSecond), 16_384, accuracy: 0.01)
        XCTAssertEqual(resumed.sessionWriteBytes, (10 * 4_096) + (2 * 16_384), accuracy: 0.01)
    }

    func testInvalidateRetainsSessionTotalsButRequiresANewBaseline() throws {
        var analyzer = SwapAnalyzer()
        _ = analyzer.ingest(snapshot(uptime: 0, swapOuts: 10))
        let before = analyzer.ingest(snapshot(uptime: 2, swapOuts: 20))
        XCTAssertEqual(before.sessionWriteBytes, 10 * 4_096, accuracy: 0.01)

        analyzer.invalidate()
        let baseline = analyzer.ingest(snapshot(uptime: 4, swapOuts: 1_000))
        XCTAssertNil(baseline.currentWriteBytesPerSecond)
        XCTAssertEqual(baseline.sessionWriteBytes, 10 * 4_096, accuracy: 0.01)

        let resumed = analyzer.ingest(snapshot(uptime: 6, swapOuts: 1_004))
        XCTAssertEqual(try XCTUnwrap(resumed.currentWriteBytesPerSecond), 2 * 4_096, accuracy: 0.01)
        XCTAssertEqual(resumed.sessionWriteBytes, 14 * 4_096, accuracy: 0.01)
    }

    func testResetClearsSessionTotalsAndRequiresANewBaseline() {
        var analyzer = SwapAnalyzer()
        _ = analyzer.ingest(snapshot(uptime: 0, swapOuts: 10))
        _ = analyzer.ingest(snapshot(uptime: 2, swapOuts: 20))

        analyzer.reset()
        let result = analyzer.ingest(snapshot(uptime: 4, swapOuts: 100))

        XCTAssertNil(result.currentWriteBytesPerSecond)
        XCTAssertEqual(result.sessionWriteBytes, 0)
        XCTAssertEqual(result.observedSeconds, 0)
        XCTAssertEqual(result.activity, .unknown)
    }

    func testLargeUInt64DeltaIsConvertedWithoutIntegerMultiplicationOverflow() throws {
        var analyzer = SwapAnalyzer()
        _ = analyzer.ingest(snapshot(uptime: 0, pageSize: 16_384, swapOuts: 0))

        let result = analyzer.ingest(snapshot(uptime: 2, pageSize: 16_384, swapOuts: UInt64.max))
        let expectedBytes = Double(UInt64.max) * 16_384

        XCTAssertEqual(try XCTUnwrap(result.currentWriteBytesPerSecond), expectedBytes / 2, accuracy: expectedBytes * 1e-12)
        XCTAssertEqual(result.sessionWriteBytes, expectedBytes, accuracy: expectedBytes * 1e-12)
        XCTAssertTrue(result.sessionWriteBytes.isFinite)
    }

    func testRollingAverageIsTimeWeightedAndClippedToSixtySeconds() throws {
        var analyzer = SwapAnalyzer()
        var pages: UInt64 = 0
        _ = analyzer.ingest(snapshot(uptime: 0, swapOuts: pages))

        // At t=70 the window begins at t=10, three seconds into the 2 MiB/s
        // interval from t=6...13. The irregular durations ensure the result
        // must be weighted by time rather than by number of samples.
        let intervals: [(end: UInt64, duration: UInt64, rateMiB: UInt64)] = [
            (6, 6, 1),
            (13, 7, 2),
            (22, 9, 4),
            (30, 8, 0),
            (39, 9, 3),
            (49, 10, 5),
            (57, 8, 2),
            (64, 7, 1),
            (70, 6, 4)
        ]
        var result: MonitorSummary?
        for interval in intervals {
            pages += interval.rateMiB * interval.duration * 256
            result = analyzer.ingest(snapshot(
                uptime: TimeInterval(interval.end),
                swapOuts: pages
            ))
        }

        let summary = try XCTUnwrap(result)
        XCTAssertEqual(
            try XCTUnwrap(summary.averageWriteBytesPerSecond),
            (166.0 / 60.0) * mib,
            accuracy: 0.01
        )
        XCTAssertEqual(summary.observedSeconds, 60, accuracy: 0.001)
    }

    func testFrequentClassificationRequiresThirtySecondsOfObservation() {
        var analyzer = SwapAnalyzer()
        let thresholds = MonitorThresholds(
            sustainedMiBPerSecond: 100,
            frequentWriteFraction: 0.25,
            activeMiBPerSecond: 1
        )
        var pages: UInt64 = 0
        _ = analyzer.ingest(snapshot(uptime: 0, swapOuts: pages), thresholds: thresholds)

        var beforeThirty: MonitorSummary?
        var final: MonitorSummary?
        for second in 1...30 {
            // Eight one-second active intervals out of thirty exceeds the 25% threshold.
            if second <= 8 {
                pages += 2 * 256
            }
            let value = analyzer.ingest(snapshot(uptime: TimeInterval(second), swapOuts: pages), thresholds: thresholds)
            if second == 29 { beforeThirty = value }
            if second == 30 { final = value }
        }

        XCTAssertNotEqual(beforeThirty?.activity, .frequent)
        XCTAssertEqual(final?.writeActiveFraction ?? -1, 8.0 / 30.0, accuracy: 0.0001)
        XCTAssertEqual(final?.activity, .frequent)
    }

    func testSustainedClassificationRequiresThirtySecondsOfObservation() {
        var analyzer = SwapAnalyzer()
        let thresholds = MonitorThresholds(
            sustainedMiBPerSecond: 5,
            frequentWriteFraction: 0.99,
            activeMiBPerSecond: 1
        )
        var pages: UInt64 = 0
        _ = analyzer.ingest(snapshot(uptime: 0, swapOuts: pages), thresholds: thresholds)

        var beforeThirty: MonitorSummary?
        var final: MonitorSummary?
        for second in 1...30 {
            pages += 6 * 256
            let value = analyzer.ingest(snapshot(uptime: TimeInterval(second), swapOuts: pages), thresholds: thresholds)
            if second == 29 { beforeThirty = value }
            if second == 30 { final = value }
        }

        XCTAssertNotEqual(beforeThirty?.activity, .sustained)
        XCTAssertEqual(final?.averageWriteBytesPerSecond ?? -1, 6 * mib, accuracy: 0.01)
        XCTAssertEqual(final?.activity, .sustained)
    }

    func testChurningTakesPrecedenceWhenSustainedWritesAlsoHaveActiveReads() {
        var analyzer = SwapAnalyzer()
        var reads: UInt64 = 0
        var writes: UInt64 = 0
        _ = analyzer.ingest(snapshot(uptime: 0, swapIns: reads, swapOuts: writes))

        var result: MonitorSummary?
        for second in 1...30 {
            reads += 2 * 256
            writes += 6 * 256
            result = analyzer.ingest(snapshot(
                uptime: TimeInterval(second),
                swapIns: reads,
                swapOuts: writes
            ))
        }

        XCTAssertEqual(result?.activity, .churning)
    }

    func testReadsDoNotIncreaseWriteMetricsOrTriggerWriteClassifications() throws {
        var analyzer = SwapAnalyzer()
        var reads: UInt64 = 0
        _ = analyzer.ingest(snapshot(uptime: 0, swapIns: reads, swapOuts: 0))

        var result: MonitorSummary?
        for second in 1...30 {
            reads += 20 * 256
            result = analyzer.ingest(snapshot(uptime: TimeInterval(second), swapIns: reads, swapOuts: 0))
        }

        let summary = try XCTUnwrap(result)
        XCTAssertEqual(try XCTUnwrap(summary.currentWriteBytesPerSecond), 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(summary.averageWriteBytesPerSecond), 0, accuracy: 0.01)
        XCTAssertEqual(summary.sessionWriteBytes, 0)
        XCTAssertEqual(summary.sessionReadBytes, 30 * 20 * mib, accuracy: 0.01)
        XCTAssertEqual(summary.activity, .idle)
    }

    func testIdleClassificationAfterMinimumObservationWithNoCounterMovement() {
        var analyzer = SwapAnalyzer()
        _ = analyzer.ingest(snapshot(uptime: 0, swapOuts: 0))

        var result: MonitorSummary?
        for second in 1...30 {
            result = analyzer.ingest(snapshot(uptime: TimeInterval(second), swapOuts: 0))
        }

        XCTAssertEqual(result?.activity, .idle)
        XCTAssertEqual(result?.writeActiveFraction ?? -1, 0, accuracy: 0.001)
    }

    func testZeroThresholdsDoNotClassifyZeroTrafficAsActivity() {
        var analyzer = SwapAnalyzer()
        let thresholds = MonitorThresholds(
            sustainedMiBPerSecond: 0,
            frequentWriteFraction: 0,
            activeMiBPerSecond: 0
        )
        _ = analyzer.ingest(snapshot(uptime: 0), thresholds: thresholds)

        var result: MonitorSummary?
        for second in 1...30 {
            result = analyzer.ingest(
                snapshot(uptime: TimeInterval(second)),
                thresholds: thresholds
            )
        }

        XCTAssertEqual(result?.currentWriteBytesPerSecond, 0)
        XCTAssertEqual(result?.writeActiveFraction, 0)
        XCTAssertEqual(result?.activity, .idle)
    }

    func testHistoryIsBoundedToTenMinutes() throws {
        var analyzer = SwapAnalyzer()
        var pages: UInt64 = 0
        _ = analyzer.ingest(snapshot(uptime: 0, swapOuts: pages))

        var result: MonitorSummary?
        for second in stride(from: 2, through: 800, by: 2) {
            pages += 256
            result = analyzer.ingest(snapshot(uptime: TimeInterval(second), swapOuts: pages))
        }

        let summary = try XCTUnwrap(result)
        XCTAssertLessThanOrEqual(summary.history.count, 301)
        XCTAssertGreaterThan(summary.history.count, 0)
    }

    private func snapshot(
        uptime: TimeInterval,
        pageSize: UInt64 = 4_096,
        swapIns: UInt64 = 0,
        swapOuts: UInt64 = 0,
        swapUsedBytes: UInt64? = 0,
        swapAllocatedBytes: UInt64? = 0,
        pressure: MemoryPressure = .normal
    ) -> MemorySnapshot {
        MemorySnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + uptime),
            uptime: uptime,
            pageSize: pageSize,
            swapIns: swapIns,
            swapOuts: swapOuts,
            swapUsedBytes: swapUsedBytes,
            swapAllocatedBytes: swapAllocatedBytes,
            physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
            compressedBytes: 2 * 1_024 * 1_024 * 1_024,
            wiredBytes: 3 * 1_024 * 1_024 * 1_024,
            diskFreeBytes: 200 * 1_024 * 1_024 * 1_024,
            diskTotalBytes: 1_000 * 1_024 * 1_024 * 1_024,
            pressure: pressure,
            issues: []
        )
    }
}
