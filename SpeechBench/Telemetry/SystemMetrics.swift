import Darwin
import Foundation
import os

/// Thin wrappers over the mach / kernel counters iOS lets an app read about itself
/// (and, where the sandbox allows, the whole system). Every reader returns nil
/// rather than guessing when the kernel refuses the call.
enum SystemMetrics {
    private static let host = mach_host_self()

    // MARK: - This process

    /// Total CPU time (user + system) this process has consumed, in seconds.
    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Kernel energy accounting for this process (TASK_POWER_INFO_V2).
    /// `energyNJ` is the kernel's CPU energy estimate in nanojoules. It does not
    /// include Neural Engine work. `gpuNS` is GPU time charged to the process.
    static func processPower() -> (energyNJ: UInt64, gpuNS: UInt64)? {
        #if arch(arm64)
        var info = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (info.task_energy, info.gpu_energy.task_gpu_utilisation)
        #else
        return nil  // task_energy only exists on arm64
        #endif
    }

    /// Physical footprint — the number Xcode's memory gauge and jetsam use.
    static func processFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// Bytes this process can still allocate before iOS terminates it. 0 on the simulator.
    static func availableBytes() -> UInt64 { UInt64(os_proc_available_memory()) }

    // MARK: - Whole system

    struct CoreTicks { var busy: UInt64; var total: UInt64 }

    /// Cumulative busy/total ticks per CPU core.
    static func coreTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(cpuCount)).map { cpu in
            let base = Int(CPU_STATE_MAX) * cpu
            func ticks(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            let busy = ticks(CPU_STATE_USER) + ticks(CPU_STATE_SYSTEM) + ticks(CPU_STATE_NICE)
            return CoreTicks(busy: busy, total: busy + ticks(CPU_STATE_IDLE))
        }
    }

    /// System-wide memory in use (active + wired + compressed), in bytes.
    static func systemUsedBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }
}
