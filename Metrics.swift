import Foundation
import Darwin
import IOKit

struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func utilization(since old: CPUTicks) -> Double? {
        let busy = UInt64(user &- old.user) + UInt64(system &- old.system) + UInt64(nice &- old.nice)
        let total = busy + UInt64(idle &- old.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }
}

struct MemoryMetric {
    let total: Double
    let occupied: Double
    let compressed: Double
    let swap: Double?
    let pressure: Int?
    var percent: Double { occupied / total * 100 }
    var pressureLabel: String {
        switch pressure {
        case 1: return "压力正常"
        case 2: return "压力偏高"
        case 4: return "压力很高"
        default: return "压力未知"
        }
    }

    static func usedBytes(statistics info: vm_statistics64_data_t, pageSize: vm_size_t) -> Double {
        // Purgeable anonymous pages are cache; count compressed pages at their physical size.
        let applicationPages = max(0, Double(info.internal_page_count) - Double(info.purgeable_count))
        return (applicationPages + Double(info.wire_count) + Double(info.compressor_page_count)) * Double(pageSize)
    }
}

struct DiskMetric {
    let total: Double
    let free: Double
    var used: Double { total - free }
    var percent: Double { used / total * 100 }
}

struct PowerMetric {
    let watts: Double
    let updatedAt: Date

    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        return age >= -5 && age < 180
    }

    static func decode(_ properties: [String: Any], at now: Date) -> PowerMetric? {
        guard let telemetry = properties["PowerTelemetryData"] as? [String: Any],
              let power = telemetry["SystemPowerIn"] as? NSNumber,
              let timestamp = properties["UpdateTime"] as? NSNumber,
              (properties["ExternalConnected"] as? NSNumber)?.boolValue == true else { return nil }
        let watts = power.doubleValue / 1000
        let date = Date(timeIntervalSince1970: timestamp.doubleValue)
        guard watts.isFinite, watts >= 0, watts < 1000, date.timeIntervalSince1970 > 0,
              date.timeIntervalSince(now) <= 5 else { return nil }
        return PowerMetric(watts: watts, updatedAt: date)
    }
}

struct MetricsSnapshot {
    let sampledAt: Date
    let cpu: Double?
    let memory: MemoryMetric?
    let disk: DiskMetric?
    let power: PowerMetric?
}

final class MetricsCollector {
    private let host = mach_host_self()
    private var previousCPU: CPUTicks?
    private var cachedDisk: DiskMetric?
    private var lastDiskRead = Date.distantPast
    private var cachedPower: PowerMetric?
    private var lastPowerRead = Date.distantPast
    private let diskReadInterval: TimeInterval
    private let powerReadInterval: TimeInterval

    init(diskReadInterval: TimeInterval = 15, powerReadInterval: TimeInterval = 5) {
        self.diskReadInterval = diskReadInterval
        self.powerReadInterval = powerReadInterval
    }

    deinit { mach_port_deallocate(mach_task_self_, host) }

    func reset() {
        previousCPU = nil
        lastDiskRead = .distantPast
        lastPowerRead = .distantPast
    }

    func sample(now: Date = Date()) -> MetricsSnapshot {
        let ticks = readCPUTicks()
        let cpu: Double?
        if let ticks, let previousCPU { cpu = ticks.utilization(since: previousCPU) }
        else { cpu = nil }
        previousCPU = ticks
        if now.timeIntervalSince(lastDiskRead) >= diskReadInterval {
            cachedDisk = readDisk()
            lastDiskRead = now
        }
        if now.timeIntervalSince(lastPowerRead) >= powerReadInterval {
            cachedPower = readPower(now: now)
            lastPowerRead = now
        }
        return MetricsSnapshot(sampledAt: now, cpu: cpu, memory: readMemory(), disk: cachedDisk, power: cachedPower)
    }

    private func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func readMemory() -> MemoryMetric? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let used = MemoryMetric.usedBytes(statistics: info, pageSize: pageSize)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)
        return MemoryMetric(total: total, occupied: max(0, min(total, used)),
                            compressed: Double(info.compressor_page_count) * Double(pageSize),
                            swap: swapResult == 0 ? Double(swap.xsu_used) : nil,
                            pressure: pressureResult == 0 ? Int(pressure) : nil)
    }

    private func readDisk() -> DiskMetric? {
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity,
              total > 0, free >= 0, free <= total else { return nil }
        // APFS volumes share free space; total minus available includes sibling system volumes.
        return DiskMetric(total: Double(total), free: Double(free))
    }

    private func readPower(now: Date) -> PowerMetric? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return PowerMetric.decode(dictionary, at: now)
    }
}

func chipName() -> String {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0 else { return "Mac" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "Mac" }
    return String(cString: buffer).replacingOccurrences(of: "Apple ", with: "")
}
