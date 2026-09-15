import XCTest
@testable import SwapCore

final class SystemSamplerSmokeTests: XCTestCase {
    func testNativeSampleAcceptsTheRunningKernelsVMStatisticsRevision() throws {
        // The active SDK may define a larger vm_statistics64 revision than the
        // running kernel returns. Sampling is valid when the returned prefix
        // contains every field SwapWatch reads; optional sysctls may still be
        // unavailable and are represented in `issues`.
        let sample = try SystemSampler().sample()

        XCTAssertGreaterThan(sample.uptime, 0)
        XCTAssertGreaterThan(sample.pageSize, 0)
        XCTAssertGreaterThan(sample.physicalMemoryBytes, 0)
        XCTAssertLessThanOrEqual(sample.wiredBytes, sample.physicalMemoryBytes)
        XCTAssertLessThanOrEqual(sample.compressedBytes, sample.physicalMemoryBytes)
    }
}
