import AppKit
import Darwin
import IOKit.ps

struct ProcessIdentity: Hashable {
    let pid: Int32
    let startedAt: UInt64
}

struct ProcessMetric {
    let identity: ProcessIdentity
    let name: String
    let path: String
    let uid: uid_t
    let cpu: Double?
    let memory: UInt64
    let energyWatts: Double?
    let wakeups: Double?
    var memoryPercent: Double { Double(memory) / Double(ProcessInfo.processInfo.physicalMemory) * 100 }
}

struct ProcessReading {
    let startedAt: UInt64
    let cpuTime: UInt64
    let memory: UInt64
    let energy: UInt64?
    let wakeups: UInt64

    static func read(_ pid: Int32) -> ProcessReading? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        if result == 0 {
            return ProcessReading(startedAt: usage.ri_proc_start_abstime, cpuTime: usage.ri_user_time + usage.ri_system_time,
                memory: usage.ri_phys_footprint, energy: usage.ri_energy_nj, wakeups: usage.ri_pkg_idle_wkups)
        }
        var fallback = rusage_info_v4()
        let fallbackResult = withUnsafeMutablePointer(to: &fallback) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard fallbackResult == 0 else { return nil }
        return ProcessReading(startedAt: fallback.ri_proc_start_abstime, cpuTime: fallback.ri_user_time + fallback.ri_system_time,
            memory: fallback.ri_phys_footprint, energy: nil, wakeups: fallback.ri_pkg_idle_wkups)
    }

    static func rate(_ value: UInt64?, previous: UInt64?, seconds: Double) -> Double? {
        guard let value, let previous, value >= previous, seconds > 0, seconds <= 3 else { return nil }
        return Double(value - previous) / seconds
    }
}

struct BatteryTelemetry {
    let designCapacityMAh: Double?
    let fullChargeCapacityMAh: Double?
    let cycleCount: Int?
    let temperatureCelsius: Double?
    let voltage: Double?
    let currentAmps: Double?

    var healthPercent: Double? {
        guard let designCapacityMAh, let fullChargeCapacityMAh else { return nil }
        return min(100, fullChargeCapacityMAh / designCapacityMAh * 100)
    }
    var watts: Double? {
        guard let voltage, let currentAmps else { return nil }
        return voltage * currentAmps
    }
    static func decode(_ properties: [String: Any]) -> BatteryTelemetry {
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        func positive(_ values: Any?...) -> Double? {
            values.compactMap { ($0 as? NSNumber)?.doubleValue }.first { $0.isFinite && $0 > 0 }
        }
        let design = positive(properties["DesignCapacity"], data["DesignCapacity"])
        let full = positive(properties["AppleRawMaxCapacity"], properties["NominalChargeCapacity"], data["NominalChargeCapacity"], data["FullChargeCapacity"])
        let rawTemperature = (properties["Temperature"] as? NSNumber)?.doubleValue
        let temperature = rawTemperature.map { $0 / 100 }
        let voltage = positive(properties["Voltage"]).map { $0 / 1000 }
        let rawCurrent = (properties["InstantAmperage"] as? NSNumber) ?? (properties["Amperage"] as? NSNumber)
        // IORegistry may encode negative discharge current as an unsigned two's-complement integer.
        let current = rawCurrent.flatMap { number -> Double? in
            guard number.doubleValue.isFinite else { return nil }
            let signed = number.int64Value
            let milliamps = signed > Int32.max && signed <= UInt32.max ? Int64(Int32(bitPattern: number.uint32Value)) : signed
            return Double(milliamps) / 1000
        }
        let cycles = (properties["CycleCount"] as? NSNumber)?.intValue
        return BatteryTelemetry(designCapacityMAh: design, fullChargeCapacityMAh: full,
            cycleCount: cycles.flatMap { $0 >= 0 ? $0 : nil },
            temperatureCelsius: temperature.flatMap { $0.isFinite && (-20...100).contains($0) ? $0 : nil },
            voltage: voltage.flatMap { $0 <= 30 ? $0 : nil },
            currentAmps: current.flatMap { abs($0) <= 50 ? $0 : nil })
    }
    static func read() -> BatteryTelemetry? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return decode(dictionary)
    }
}

struct BatteryMetric {
    let percent: Double?
    let charging: Bool
    let external: Bool
    let minutesRemaining: Int?
    let health: String?
    var charged: Bool = false
    var telemetry: BatteryTelemetry? = nil

    static func decode(_ info: [String: Any]) -> BatteryMetric? {
        guard info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              (info[kIOPSIsPresentKey] as? NSNumber)?.boolValue != false else { return nil }
        let current = (info[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
        let maximum = (info[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
        let percent: Double?
        if let current, let maximum, maximum > 0, current >= 0 {
            percent = min(100, current / maximum * 100)
        } else { percent = nil }
        let charging = (info[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false
        let external = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let minutes = (info[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? NSNumber)?.intValue
        let health = info[kIOPSBatteryHealthKey] as? String
        return BatteryMetric(percent: percent, charging: charging, external: external,
            minutesRemaining: (charging || !external) && (minutes ?? 0) > 0 ? minutes : nil, health: health,
            charged: (info[kIOPSIsChargedKey] as? NSNumber)?.boolValue ?? false)
    }

    static func read() -> BatteryMetric? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               var battery = decode(description) {
                battery.telemetry = BatteryTelemetry.read()
                return battery
            }
        }
        return nil
    }

    var summary: String {
        "电池 \(MenuBarText.percent(percent)) · \(statusSummary)"
    }

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        guard let percent else { return "battery.0percent" }
        switch percent {
        case ..<10: return "battery.0percent"
        case ..<35: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var statusSummary: String {
        var parts = [powerSummary]
        if let healthLabel { parts.append("健康状态：\(healthLabel)") }
        return parts.joined(separator: " · ")
    }

    var healthLabel: String? {
        health.map { ["Good": "正常", "Fair": "一般", "Poor": "较差", "Check Battery": "建议检修"][$0] ?? $0 }
    }

    var stateLabel: String {
        if charging { return "正在充电" }
        if external { return charged ? "已充满 · 外接电源" : "外接电源 · 未充电" }
        return "电池供电"
    }

    var powerSummary: String {
        var parts = [stateLabel]
        if let minutesRemaining { parts.append("\(charging ? "充满约需" : "预计剩余") \(minutesRemaining / 60) 小时 \(minutesRemaining % 60) 分钟") }
        return parts.joined(separator: " · ")
    }
}

struct DetailedSnapshot {
    let cores: [Double?]
    let processes: [ProcessMetric]
    let totalProcesses: Int
    let energyAvailable: Bool
    let battery: BatteryMetric?
}

final class DetailedCollector {
    private struct Previous {
        let reading: ProcessReading
        let name: String
        let path: String
        let uid: uid_t
    }
    private var previous: [Int32: Previous] = [:]
    private var previousCores: [CPUTicks] = []
    private var lastTime: Double?
    private var sampleNumber = 0
    private let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()
    private let host = mach_host_self()
    deinit { mach_port_deallocate(mach_task_self_, host) }

    func sample() -> DetailedSnapshot {
        sampleNumber += 1
        let time = ProcessInfo.processInfo.systemUptime
        let interval = lastTime.map { time - $0 } ?? 0
        if interval > 3 { previous = [:]; previousCores = [] }
        var pids = [Int32](repeating: 0, count: max(256, Int(proc_listallpids(nil, 0)) + 256))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var next: [Int32: Previous] = [:]
        var processes: [ProcessMetric] = []
        var energyAvailable = false
        for pid in pids.prefix(max(0, min(Int(count), pids.count))) where pid > 0 {
            guard let reading = ProcessReading.read(pid) else { continue }
            let old = previous[pid].flatMap { $0.reading.startedAt == reading.startedAt ? $0 : nil }
            let metadata: Previous
            if let old, sampleNumber % 5 != 0 { metadata = Previous(reading: reading, name: old.name, path: old.path, uid: old.uid) }
            else {
                var bsd = proc_bsdinfo()
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd))) == MemoryLayout.size(ofValue: bsd) else { continue }
                var path = [CChar](repeating: 0, count: 4096)
                _ = proc_pidpath(pid, &path, UInt32(path.count))
                var name = [CChar](repeating: 0, count: 256)
                _ = proc_name(pid, &name, UInt32(name.count))
                metadata = Previous(reading: reading, name: String(cString: name), path: String(cString: path), uid: bsd.pbi_uid)
            }
            next[pid] = metadata
            energyAvailable = energyAvailable || (reading.energy ?? 0) > 0
            // libproc CPU times use Mach ticks; process energy is already in nanojoules.
            let cpu = ProcessReading.rate(reading.cpuTime, previous: old?.reading.cpuTime, seconds: interval).map { $0 * nanosecondsPerTick / 1e9 * 100 }
            let energy = ProcessReading.rate(reading.energy, previous: old?.reading.energy, seconds: interval).map { $0 / 1e9 }
            processes.append(ProcessMetric(identity: ProcessIdentity(pid: pid, startedAt: reading.startedAt),
                name: metadata.name.isEmpty ? "PID \(pid)" : metadata.name, path: metadata.path, uid: metadata.uid,
                cpu: cpu, memory: reading.memory, energyWatts: energy,
                wakeups: ProcessReading.rate(reading.wakeups, previous: old?.reading.wakeups, seconds: interval)))
        }
        previous = next
        lastTime = time
        return DetailedSnapshot(cores: readCores(), processes: processes, totalProcesses: max(0, Int(count)),
            energyAvailable: energyAvailable, battery: BatteryMetric.read())
    }

    private func readCores() -> [Double?] {
        var count: mach_msg_type_number_t = 0
        var cores: natural_t = 0
        var pointer: processor_info_array_t?
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cores, &pointer, &count) == KERN_SUCCESS,
              let pointer else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: pointer)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        guard Int(count) >= Int(cores) * Int(CPU_STATE_MAX) else { return [] }
        var ticks: [CPUTicks] = []
        for core in 0..<Int(cores) {
            let start = core * Int(CPU_STATE_MAX)
            ticks.append(CPUTicks(user: UInt32(bitPattern: pointer[start + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: pointer[start + Int(CPU_STATE_SYSTEM)]), idle: UInt32(bitPattern: pointer[start + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: pointer[start + Int(CPU_STATE_NICE)])))
        }
        let values = ticks.enumerated().map { index, ticks -> Double? in
            previousCores.count == Int(cores) ? ticks.utilization(since: previousCores[index]) : nil
        }
        previousCores = ticks
        return values
    }
}

final class DetailedMonitor {
    var onSample: ((DetailedSnapshot) -> Void)?
    private let queue = DispatchQueue(label: "local.macpulse.details", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var generation = UUID()

    func start() {
        guard timer == nil else { return }
        let collector = DetailedCollector()
        let token = UUID()
        generation = token
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            let sample = collector.sample()
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in
                guard let self, self.timer != nil, self.generation == token else { return }
                self.onSample?(sample)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() { generation = UUID(); timer?.cancel(); timer = nil }
    deinit { timer?.cancel() }
}

enum ProcessActions {
    static func protectionReason(_ process: ProcessMetric) -> String? {
        if process.identity.pid <= 1 || process.uid != getuid() { return "系统或其他用户的进程" }
        if process.identity.pid == getpid() { return "当前监视程序" }
        let protected = ["launchd", "loginwindow", "WindowServer", "Dock", "Finder", "SystemUIServer", "SystemStatusWidget", "DesktopMonitor"]
        if protected.contains(process.name) { return "系统关键进程" }
        if process.path.isEmpty || ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"].contains(where: { process.path.hasPrefix($0) }) {
            return "系统进程"
        }
        var ancestor = getppid()
        var visited = Set<Int32>()
        while ancestor > 1 && visited.insert(ancestor).inserted {
            if ancestor == process.identity.pid { return "监视程序的上级进程" }
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(ancestor, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd))) > 0 else { break }
            ancestor = Int32(bsd.pbi_ppid)
        }
        return nil
    }

    static func terminate(_ selected: ProcessMetric, force: Bool) throws {
        func failure(_ text: String) -> NSError { NSError(domain: "MacPulse", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        if let reason = protectionReason(selected) { throw failure("不能退出：\(reason)。") }
        guard let current = ProcessReading.read(selected.identity.pid), current.startedAt == selected.identity.startedAt else {
            throw failure("该进程已结束或已重新启动，请重新选择。")
        }
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(selected.identity.pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd))) > 0,
              bsd.pbi_uid == getuid() else { throw failure("进程身份发生变化，操作已取消。") }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(selected.identity.pid, &path, UInt32(path.count)) > 0,
              String(cString: path) == selected.path else { throw failure("进程执行文件已变化，请重新选择。") }
        if !force, let application = NSRunningApplication(processIdentifier: selected.identity.pid) {
            guard application.terminate() else { throw failure("应用没有接受退出请求。") }
        } else if kill(selected.identity.pid, force ? SIGKILL : SIGTERM) != 0 {
            throw failure("无法退出进程：\(String(cString: strerror(errno)))")
        }
    }
}
