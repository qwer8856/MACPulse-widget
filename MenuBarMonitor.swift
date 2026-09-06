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

    init(title: String, symbol: String, color: NSColor) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!)
        icon.contentTintColor = color
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        value.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        value.alignment = .right
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for view in [icon, label, value, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 43),
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(value: String, detail: String) {
        self.value.stringValue = value
        self.detail.stringValue = detail
    }
}

final class MenuBarContentView: NSView {
    private let cpu = MenuMetricRow(title: "CPU", symbol: "cpu", color: .systemCyan)
    private let memory = MenuMetricRow(title: "内存", symbol: "memorychip", color: .systemGreen)
    private let disk = MenuMetricRow(title: "磁盘", symbol: "internaldrive", color: .systemOrange)
    private let power = MenuMetricRow(title: "功率", symbol: "bolt.fill", color: .systemPink)
    private let pressure = NSTextField(labelWithString: "压力未知")
    private let timestamp = NSTextField(labelWithString: "--:--:--")
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 244))
        let title = NSTextField(labelWithString: "系统状态")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        timestamp.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timestamp.textColor = .secondaryLabelColor
        pressure.font = .systemFont(ofSize: 11, weight: .medium)
        for view in [title, timestamp, cpu, memory, disk, power, pressure] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            timestamp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            timestamp.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            timestamp.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            cpu.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            memory.topAnchor.constraint(equalTo: cpu.bottomAnchor),
            disk.topAnchor.constraint(equalTo: memory.bottomAnchor),
            power.topAnchor.constraint(equalTo: disk.bottomAnchor),
            pressure.topAnchor.constraint(equalTo: power.bottomAnchor, constant: 5),
            pressure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            pressure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])
        for row in [cpu, memory, disk, power] {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ snapshot: MetricsSnapshot) {
        cpu.update(value: MenuBarText.percent(snapshot.cpu), detail: "\(ProcessInfo.processInfo.processorCount) 核")
        memory.update(value: MenuBarText.percent(snapshot.memory?.percent), detail: snapshot.memory.map {
            String(format: "已用 %.1f / %.0f GiB · 压缩 %.1f GiB", $0.occupied / 1_073_741_824, $0.total / 1_073_741_824, $0.compressed / 1_073_741_824)
        } ?? "暂无数据")
        disk.update(value: MenuBarText.percent(snapshot.disk?.percent), detail: snapshot.disk.map {
            String(format: "可用 %.0f / %.0f GB", $0.free / 1e9, $0.total / 1e9)
        } ?? "暂无数据")
        let currentPower = MenuBarText.freshPower(snapshot)
        power.update(value: currentPower.map { String(format: "%.1f W", $0.watts) } ?? "--",
                     detail: currentPower == nil ? "暂无有效读数" : "供电侧估算")
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
