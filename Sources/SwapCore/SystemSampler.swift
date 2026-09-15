import Darwin
import Foundation

public enum SystemSamplerError: Error, LocalizedError, Sendable {
    case pageSize(Int32)
    case virtualMemoryStatistics(Int32)
    case incompleteVirtualMemoryStatistics(expected: UInt32, received: UInt32)
    case physicalMemoryUnavailable
    case byteCountOverflow(String)

    public var errorDescription: String? {
        switch self {
        case let .pageSize(code):
            return "host_page_size failed with Mach error \(code)."
        case let .virtualMemoryStatistics(code):
            return "host_statistics64 failed with Mach error \(code)."
        case let .incompleteVirtualMemoryStatistics(expected, received):
            return "host_statistics64 returned \(received) values; \(expected) were required."
        case .physicalMemoryUnavailable:
            return "The physical memory size was unavailable."
        case let .byteCountOverflow(metric):
            return "The \(metric) byte count exceeded UInt64."
        }
    }
}

/// Reads cumulative VM counters directly from Darwin. No helper process,
/// shell polling, or root privileges are required.
public struct SystemSampler: Sendable {
    public init() {}

    public func sample() throws -> MemorySnapshot {
        // `mach_host_self` creates a send right owned by the caller. Reusing it
        // for both host calls and releasing it here avoids leaking a right on
        // every polling interval.
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        let pageSize = try readPageSize(host: host)
        let statistics = try readVMStatistics(host: host)
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        guard physicalMemory > 0 else {
            throw SystemSamplerError.physicalMemoryUnavailable
        }

        var issues: [String] = []

        let swap: (used: UInt64, allocated: UInt64)?
        do {
            swap = try readSwapUsage()
        } catch {
            swap = nil
            issues.append("Swap allocation is unavailable: \(error.localizedDescription)")
        }

        let pressure: MemoryPressure
        do {
            pressure = try readMemoryPressure()
        } catch {
            pressure = .unknown
            issues.append("Memory pressure is unavailable: \(error.localizedDescription)")
        }

        let disk: (free: UInt64, total: UInt64)?
        do {
            disk = try readSwapVolumeCapacity()
        } catch {
            disk = nil
            issues.append("Swap-volume capacity is unavailable: \(error.localizedDescription)")
        }

        return MemorySnapshot(
            timestamp: Date(),
            uptime: ProcessInfo.processInfo.systemUptime,
            pageSize: pageSize,
            swapIns: statistics.swapins,
            swapOuts: statistics.swapouts,
            swapUsedBytes: swap?.used,
            swapAllocatedBytes: swap?.allocated,
            physicalMemoryBytes: physicalMemory,
            compressedBytes: try byteCount(
                pages: statistics.compressor_page_count,
                pageSize: pageSize,
                metric: "compressed memory"
            ),
            wiredBytes: try byteCount(
                pages: statistics.wire_count,
                pageSize: pageSize,
                metric: "wired memory"
            ),
            diskFreeBytes: disk?.free,
            diskTotalBytes: disk?.total,
            pressure: pressure,
            issues: issues
        )
    }
}

private struct POSIXFailure: LocalizedError {
    let operation: String
    let code: Int32

    var errorDescription: String? {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

private struct MetricFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private extension SystemSampler {
    func readPageSize(host: host_t) throws -> UInt64 {
        var size: vm_size_t = 0
        let result = host_page_size(host, &size)
        guard result == KERN_SUCCESS, size > 0 else {
            throw SystemSamplerError.pageSize(result)
        }
        return UInt64(size)
    }

    func readVMStatistics(host: host_t) throws -> vm_statistics64 {
        var statistics = vm_statistics64()
        let bufferCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let lastUsedFieldEnd = MemoryLayout<vm_statistics64_data_t>.offset(
            of: \vm_statistics64_data_t.compressor_page_count
        )! + MemoryLayout<natural_t>.size
        let integerSize = MemoryLayout<integer_t>.size
        let minimumUsedCount = mach_msg_type_number_t(
            (lastUsedFieldEnd + integerSize - 1) / integerSize
        )
        var count = bufferCount
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw SystemSamplerError.virtualMemoryStatistics(result)
        }
        // The SDK's vm_statistics64 may contain fields from a newer revision
        // than the running kernel supports. We offer the full buffer above,
        // but only require the response to extend through the final field this
        // sampler reads. Older kernels can therefore return a shorter, valid
        // revision without making the entire sample fail.
        guard count >= minimumUsedCount else {
            throw SystemSamplerError.incompleteVirtualMemoryStatistics(
                expected: minimumUsedCount,
                received: count
            )
        }
        return statistics
    }

    func readSwapUsage() throws -> (used: UInt64, allocated: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else {
            throw POSIXFailure(operation: "sysctl vm.swapusage", code: errno)
        }
        guard size >= MemoryLayout<xsw_usage>.size else {
            throw MetricFailure(message: "sysctl vm.swapusage returned an incomplete value")
        }
        return (usage.xsu_used, usage.xsu_total)
    }

    func readMemoryPressure() throws -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname(
            "kern.memorystatus_vm_pressure_level",
            &level,
            &size,
            nil,
            0
        )
        guard result == 0 else {
            throw POSIXFailure(
                operation: "sysctl kern.memorystatus_vm_pressure_level",
                code: errno
            )
        }
        guard size >= MemoryLayout<Int32>.size else {
            throw MetricFailure(
                message: "sysctl kern.memorystatus_vm_pressure_level returned an incomplete value"
            )
        }

        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default:
            throw MetricFailure(message: "the kernel returned unknown memory-pressure level \(level)")
        }
    }

    func readSwapVolumeCapacity() throws -> (free: UInt64, total: UInt64) {
        var lastError = ENOENT
        // `/private/var/vm` is the actual swap directory. The Data-volume path
        // also works before the swap directory has been created or exposed.
        for path in ["/private/var/vm", "/System/Volumes/Data"] {
            var information = statfs()
            let result = path.withCString { statfs($0, &information) }
            guard result == 0 else {
                lastError = errno
                continue
            }

            let blockSize = UInt64(information.f_bsize)
            let free = try multiplied(
                UInt64(information.f_bavail),
                blockSize,
                metric: "swap-volume free-space"
            )
            let total = try multiplied(
                UInt64(information.f_blocks),
                blockSize,
                metric: "swap-volume total-space"
            )
            return (free, total)
        }
        throw POSIXFailure(operation: "statfs for the swap volume", code: lastError)
    }

    func byteCount<T: BinaryInteger>(
        pages: T,
        pageSize: UInt64,
        metric: String
    ) throws -> UInt64 {
        guard let pageCount = UInt64(exactly: pages) else {
            throw SystemSamplerError.byteCountOverflow(metric)
        }
        return try multiplied(pageCount, pageSize, metric: metric)
    }

    func multiplied(_ left: UInt64, _ right: UInt64, metric: String) throws -> UInt64 {
        let result = left.multipliedReportingOverflow(by: right)
        guard !result.overflow else {
            throw SystemSamplerError.byteCountOverflow(metric)
        }
        return result.partialValue
    }
}
