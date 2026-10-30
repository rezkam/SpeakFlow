import Darwin
import Foundation

/// Live process counters only. These do not isolate model or accelerator memory.
struct LocalProcessResourceUsage {
    private(set) var memoryBytes: UInt64?
    private(set) var residentBytes: UInt64?
    private(set) var cpuPercent: Double?
    private var previousCPU: Double?
    private var previousTime: TimeInterval?

    mutating func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        if let previousTime, now - previousTime < 1 { return }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        memoryBytes = result == KERN_SUCCESS ? info.phys_footprint : nil
        residentBytes = result == KERN_SUCCESS ? info.resident_size : nil

        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            if let previousCPU, let previousTime, now > previousTime {
                cpuPercent = max(0, (cpu - previousCPU) / (now - previousTime) * 100)
            }
            previousCPU = cpu
        } else {
            cpuPercent = nil
            previousCPU = nil
        }
        previousTime = now
    }
}
