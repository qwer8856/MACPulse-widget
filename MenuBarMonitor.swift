import AppKit

final class LiveMetricsMonitor {
    var onSample: ((MetricsSnapshot) -> Void)?
    private let queue = DispatchQueue(label: "local.macpulse.menu-sampling", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var generation = UUID()

    func start() {
        precondition(Thread.isMainThread)
        guard timer == nil else { return }
        let generation = UUID()
        self.generation = generation
        let collector = MetricsCollector(diskReadInterval: 0, powerReadInterval: 0)
        var lastSample: Date?
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            let now = Date()
            // Discard CPU deltas spanning sleep or a long scheduling delay.
            if let lastSample, now.timeIntervalSince(lastSample) > 3 {
                collector.reset()
            }
            let snapshot = collector.sample(now: now)
            lastSample = now
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in
                guard let self, self.generation == generation, self.timer != nil else { return }
                self.onSample?(snapshot)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation = UUID()
        timer?.cancel()
        timer = nil
    }

    deinit { timer?.cancel() }
}

enum MenuBarText {
    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "--"
    }

    static func title(_ snapshot: MetricsSnapshot?) -> String {
        "CPU \(percent(snapshot?.cpu))  内存 \(percent(snapshot?.memory?.percent))"
    }

    static func freshPower(_ snapshot: MetricsSnapshot) -> PowerMetric? {
        guard let power = snapshot.power, power.isFresh(at: snapshot.sampledAt) else { return nil }
        return power
    }
}

final class MenuMetricRow: NSView {
    private let value = NSTextField(labelWithString: "--")
    private let detail = NSTextField(labelWithString: "等待采样")
    private let bar: MetricBar?

    init(title: String, symbol: String, color: NSColor, showsBar: Bool = true) {
        bar = showsBar ? MetricBar(color: color) : nil
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!)
        icon.contentTintColor = color
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        value.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        value.alignment = .right
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for view in [icon, label, value, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            value.topAnchor.constraint(equalTo: topAnchor),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: topAnchor, constant: 23)
        ])
        if let bar {
            bar.translatesAutoresizingMaskIntoConstraints = false; addSubview(bar)
            bar.setAccessibilityLabel(title)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: label.leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
                bar.topAnchor.constraint(equalTo: topAnchor, constant: 42), bar.heightAnchor.constraint(equalToConstant: 6)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(value: String, detail: String, reading: Double? = nil, maximum: Double = 100, color: NSColor? = nil) {
        self.value.stringValue = value
        self.detail.stringValue = detail
        self.detail.toolTip = detail
        bar?.update(reading, maximum: maximum, color: color, description: value + "，" + detail)
    }
}

final class MenuBarContentView: NSView {
    private let cpu = MenuMetricRow(title: "CPU", symbol: "cpu", color: .systemCyan, showsBar: false)
    private let memory = MenuMetricRow(title: "内存", symbol: "memorychip", color: .systemGreen)
    private let disk = MenuMetricRow(title: "磁盘", symbol: "internaldrive", color: .systemOrange)
    private let power = MenuMetricRow(title: "功率", symbol: "bolt.fill", color: .systemPink)
    private let battery = MenuMetricRow(title: "电池", symbol: "battery.100percent", color: .systemTeal)
    private let pressure = NSTextField(labelWithString: "压力未知")
    private let timestamp = NSTextField(labelWithString: "--:--:--")
    private var powerScale = PowerScale()
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 342))
        let title = NSTextField(labelWithString: "系统状态")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        timestamp.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timestamp.textColor = .secondaryLabelColor
        pressure.font = .systemFont(ofSize: 11, weight: .medium)
        for view in [title, timestamp, cpu, memory, disk, power, battery, pressure] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            timestamp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            timestamp.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            timestamp.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            cpu.topAnchor.constraint(equalTo: topAnchor, constant: 46),
            memory.topAnchor.constraint(equalTo: cpu.bottomAnchor),
            disk.topAnchor.constraint(equalTo: memory.bottomAnchor),
            power.topAnchor.constraint(equalTo: disk.bottomAnchor),
            battery.topAnchor.constraint(equalTo: power.bottomAnchor),
            pressure.topAnchor.constraint(equalTo: battery.bottomAnchor, constant: 5),
            pressure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            pressure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])
        for row in [cpu, memory, disk, power, battery] {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateDetails(_ details: DetailedSnapshot) {
        guard let metric = details.battery else {
            battery.update(value: "无电池", detail: "无内置电池 · 外接电源")
            return
        }
        var status = metric.charging ? "正在充电" : (metric.external ? "外接电源" : "电池供电")
        if let minutes = metric.minutesRemaining {
            status += " · \(metric.charging ? "充满约需" : "预计剩余") \(minutes / 60) 小时 \(minutes % 60) 分钟"
        }
        battery.update(value: MenuBarText.percent(metric.percent), detail: status, reading: metric.percent, color: (metric.percent ?? 100) <= 20 ? .systemRed : .systemTeal)
    }

    func update(_ snapshot: MetricsSnapshot) {
        cpu.update(value: MenuBarText.percent(snapshot.cpu), detail: "\(ProcessInfo.processInfo.processorCount) 核")
        memory.update(value: MenuBarText.percent(snapshot.memory?.percent), detail: snapshot.memory.map {
            String(format: "已用 %.1f / %.0f GiB · 压缩 %.1f GiB", $0.occupied / 1_073_741_824, $0.total / 1_073_741_824, $0.compressed / 1_073_741_824)
        } ?? "暂无数据", reading: snapshot.memory?.percent, color: snapshot.memory?.pressure == 4 ? .systemRed : (snapshot.memory?.pressure == 2 ? .systemOrange : .systemGreen))
        disk.update(value: MenuBarText.percent(snapshot.disk?.percent), detail: snapshot.disk.map {
            String(format: "可用 %.0f / %.0f GB", $0.free / 1e9, $0.total / 1e9)
        } ?? "暂无数据", reading: snapshot.disk?.percent)
        let currentPower = MenuBarText.freshPower(snapshot)
        powerScale.include(currentPower?.watts)
        power.update(value: currentPower.map { String(format: "%.1f W", $0.watts) } ?? "--",
                     detail: currentPower == nil ? "暂无有效读数" : String(format: "供电侧估算 · 刻度 0–%.0f W", powerScale.maximum),
                     reading: currentPower?.watts, maximum: powerScale.maximum)
        var pressureText = snapshot.memory?.pressureLabel ?? "压力未知"
        if let swap = snapshot.memory?.swap {
            pressureText += String(format: " · 交换空间 %.1f GiB", swap / 1_073_741_824)
        }
        pressure.stringValue = pressureText
        switch snapshot.memory?.pressure {
        case 1: pressure.textColor = .systemGreen
        case 2: pressure.textColor = .systemOrange
        case 4: pressure.textColor = .systemRed
        default: pressure.textColor = .secondaryLabelColor
        }
        timestamp.stringValue = timeFormatter.string(from: snapshot.sampledAt)
    }
}
