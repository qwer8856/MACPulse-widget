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
        switch self { case .cpu: return 1; case .memory: return 2; case .disk: return 3; case .power: return 4; case .battery: return 5 }
    }
}

final class StatusDetailView: NSView {
    let kind: StatusDetail
    let cores = CoreUsageView()
    private(set) var processes: ProcessTableView?
    private let title = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "等待采样")
    private let metricSummary: MetricSummaryView?
    private var snapshot: MetricsSnapshot?
    private var details: DetailedSnapshot?
    private var isPresented = false
    var onOpenMonitor: ((Int) -> Void)?

    init(kind: StatusDetail) {
        self.kind = kind
        metricSummary = kind == .cpu ? nil : MetricSummaryView(kind: kind, compact: true)
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: kind == .disk ? 172 : (kind == .battery ? 368 : 500)))
        title.stringValue = kind.title
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        let open = NSButton(title: "资源监视", target: self, action: #selector(openMonitor))
        open.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)
        open.imagePosition = .imageLeading; open.bezelStyle = .rounded
        let header: NSView = metricSummary ?? summary
        for view in [title, header, open] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: title.leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10), header.heightAnchor.constraint(equalToConstant: metricSummary?.preferredHeight ?? 28),
            open.leadingAnchor.constraint(equalTo: title.leadingAnchor), open.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
        if kind == .battery || kind == .disk { return }
        let mode: ProcessSort = kind == .cpu ? .cpu : (kind == .memory ? .memory : .energy)
        let table = ProcessTableView(mode: mode, compact: true, allowsTermination: false)
        processes = table
        let body: NSView = table
        body.translatesAutoresizingMaskIntoConstraints = false; addSubview(body)
        var bodyTop = header.bottomAnchor
        if kind == .cpu {
            let scroll = NSScrollView()
            scroll.drawsBackground = false; scroll.hasVerticalScroller = true
            scroll.documentView = cores; cores.translatesAutoresizingMaskIntoConstraints = false
            scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
            cores.update(Array(repeating: nil, count: ProcessInfo.processInfo.processorCount))
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: summary.bottomAnchor), scroll.heightAnchor.constraint(equalToConstant: 128),
                cores.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), cores.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), cores.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
            ])
            bodyTop = scroll.bottomAnchor
        }
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: header.leadingAnchor), body.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            body.topAnchor.constraint(equalTo: bodyTop, constant: 10), body.bottomAnchor.constraint(equalTo: open.topAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh(reloadProcesses: true) }
    }
    func update(_ snapshot: MetricsSnapshot) { self.snapshot = snapshot; refresh(reloadProcesses: false) }
    func prepareForPresentation() { isPresented = true; refresh(reloadProcesses: true) }
    func endPresentation() { isPresented = false }
    func updateDetails(_ details: DetailedSnapshot?) {
        self.details = details
        refresh(reloadProcesses: true)
    }
    private func refresh(reloadProcesses: Bool) {
        let updateTable = reloadProcesses && (isPresented || window?.isVisible == true)
        if kind == .cpu {
            title.stringValue = "CPU · \(ProcessInfo.processInfo.processorCount) 个逻辑核心"
            summary.stringValue = "总利用率 \(MenuBarText.percent(snapshot?.cpu))"
            if updateTable { cores.update(details?.cores ?? Array(repeating: nil, count: ProcessInfo.processInfo.processorCount)) }
        }
        metricSummary?.update(snapshot, details: details)
        if updateTable {
            if let details { processes?.update(details) }
            else { processes?.clear() }
        }
    }
    @objc private func openMonitor() { onOpenMonitor?(kind.page) }
}
