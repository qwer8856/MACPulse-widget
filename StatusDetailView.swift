import AppKit

enum StatusDetail: String, CaseIterable {
    case cpu, memory, disk, power, battery

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .disk: return "磁盘"
        case .power: return "功率"
        case .battery: return "电池"
        }
    }
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .power: return "bolt.fill"
        case .battery: return "battery.100percent"
        }
    }
    var page: Int {
        switch self { case .cpu: return 1; case .memory: return 2; case .disk: return 3; case .power, .battery: return 4 }
    }
}

final class StatusDetailView: NSView {
    let kind: StatusDetail
    let cores = CoreUsageView()
    let disk = DiskUsageView(compact: true)
    private(set) var processes: ProcessTableView?
    private let title = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "等待采样")
    private var snapshot: MetricsSnapshot?
    private var details: DetailedSnapshot?
    var onOpenMonitor: ((Int) -> Void)?

    init(kind: StatusDetail) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 500))
        title.stringValue = kind.title
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        let open = NSButton(title: "资源监视", target: self, action: #selector(openMonitor))
        open.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)
        open.imagePosition = .imageLeading; open.bezelStyle = .rounded
        for view in [title, summary, open] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            summary.leadingAnchor.constraint(equalTo: title.leadingAnchor), summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            summary.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8), summary.heightAnchor.constraint(equalToConstant: kind == .cpu ? 28 : 76),
            open.leadingAnchor.constraint(equalTo: title.leadingAnchor), open.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
        let body: NSView
        if kind == .disk { body = disk }
        else {
            let mode: ProcessSort = kind == .cpu ? .cpu : (kind == .memory ? .memory : .energy)
            let table = ProcessTableView(mode: mode, compact: true, allowsTermination: false)
            processes = table; body = table
        }
        body.translatesAutoresizingMaskIntoConstraints = false; addSubview(body)
        var bodyTop = summary.bottomAnchor
        if kind == .cpu {
            let scroll = NSScrollView()
            scroll.drawsBackground = false; scroll.hasVerticalScroller = true
            scroll.documentView = cores; cores.translatesAutoresizingMaskIntoConstraints = false
            scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
            cores.update(Array(repeating: nil, count: ProcessInfo.processInfo.processorCount))
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: summary.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: summary.bottomAnchor), scroll.heightAnchor.constraint(equalToConstant: 128),
                cores.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), cores.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), cores.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
            ])
            bodyTop = scroll.bottomAnchor
        }
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: summary.leadingAnchor), body.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            body.topAnchor.constraint(equalTo: bodyTop, constant: 10), body.bottomAnchor.constraint(equalTo: open.topAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }
    func update(_ snapshot: MetricsSnapshot) { self.snapshot = snapshot; refresh() }
    func updateDetails(_ details: DetailedSnapshot?) {
        self.details = details
        if details == nil { processes?.clear() }
        if kind == .cpu { cores.update(details?.cores ?? Array(repeating: nil, count: ProcessInfo.processInfo.processorCount)) }
        refresh()
    }
    private func refresh() {
        switch kind {
        case .cpu:
            title.stringValue = "CPU · \(ProcessInfo.processInfo.processorCount) 个逻辑核心"
            summary.stringValue = "总利用率 \(MenuBarText.percent(snapshot?.cpu))"
        case .memory:
            if let memory = snapshot?.memory {
                summary.stringValue = "占用 \(MenuBarText.percent(memory.percent)) · \(memorySize(memory.occupied)) / \(memorySize(memory.total))\n应用 \(memorySize(memory.application ?? 0)) · 固定 \(memorySize(memory.wired ?? 0)) · 压缩 \(memorySize(memory.compressed))\n\(memory.pressureLabel) · 交换 \(memorySize(memory.swap ?? 0))"
            } else { summary.stringValue = "等待内存采样" }
        case .disk:
            summary.stringValue = snapshot?.disk.map { String(format: "占用 %.0f%% · 总容量 %.1f GB\n已用 %.1f GB · 可用 %.1f GB", $0.percent, $0.total / 1e9, ($0.total - $0.free) / 1e9, $0.free / 1e9) } ?? "等待磁盘采样"
        case .power, .battery:
            let battery = details == nil ? "正在读取电池信息" : (details?.battery?.summary ?? "无内置电池 · 外接电源")
            let power = snapshot.flatMap(MenuBarText.freshPower).map { String(format: "供电功率 %.1f W", $0.watts) } ?? "供电功率暂无有效读数"
            let energy = details?.energyAvailable == true ? "CPU 能耗估算，不含 GPU、磁盘及显示器。" : "当前系统未提供进程 CPU 能耗数据。"
            summary.stringValue = "\(battery)\n\(power)\n\(energy)"
        }
        if window != nil, let details { processes?.update(details) }
    }
    @objc private func openMonitor() { onOpenMonitor?(kind.page) }
}
