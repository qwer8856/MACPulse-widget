import AppKit

private func toolButton(_ symbol: String, _ title: String, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: target, action: action)
    button.bezelStyle = .rounded
    button.toolTip = title
    button.widthAnchor.constraint(equalToConstant: 40).isActive = true
    return button
}

func memorySize(_ bytes: Double) -> String {
    bytes >= 1_073_741_824 ? String(format: "%.2f GiB", bytes / 1_073_741_824) : String(format: "%.1f MiB", bytes / 1_048_576)
}

final class CoreUsageView: NSView {
    private(set) var values: [Double?] = []
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(max(1, (values.count + 3) / 4)) * 40 + 8) }
    func update(_ values: [Double?]) {
        if values.count != self.values.count { self.values = values; invalidateIntrinsicContentSize() }
        else { self.values = values }
        setAccessibilityElement(true)
        setAccessibilityLabel("各核心 CPU 占用")
        setAccessibilityValue(values.enumerated().map { "核心 \($0.offset + 1)：\(MenuBarText.percent($0.element))" }.joined(separator: "，"))
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let width = max(1, bounds.width / 4)
        for (index, value) in values.enumerated() {
            let rect = NSRect(x: CGFloat(index % 4) * width + 6, y: CGFloat(index / 4) * 40 + 6, width: width - 12, height: 34)
            let text = "核心 \(index + 1)   \(MenuBarText.percent(value))"
            (text as NSString).draw(at: rect.origin, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
            let bar = NSRect(x: rect.minX, y: rect.minY + 20, width: rect.width, height: 5)
            NSColor.quaternaryLabelColor.setFill(); NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            if let value {
                NSColor.systemCyan.setFill()
                NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: bar.width * max(0, min(100, value)) / 100, height: bar.height), xRadius: 2, yRadius: 2).fill()
            }
        }
    }
}

enum ProcessSort: String { case cpu, memory, energy }

final class ProcessTableView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let table = NSTableView()
    let search = NSSearchField()
    private let status = NSTextField(labelWithString: "等待采样")
    private var quitButton: NSButton!
    private var forceButton: NSButton!
    private(set) var rows: [ProcessMetric] = []
    private var sample: DetailedSnapshot?
    private let mode: ProcessSort
    private let allowsTermination: Bool
    private let compact: Bool

    init(mode: ProcessSort, compact: Bool = false, allowsTermination: Bool = true) {
        self.mode = mode
        self.allowsTermination = allowsTermination
        self.compact = compact
        super.init(frame: .zero)
        search.placeholderString = "搜索进程"
        search.delegate = self
        quitButton = toolButton("xmark.circle", "退出所选进程", target: self, action: #selector(requestQuit))
        forceButton = toolButton("exclamationmark.octagon", "强制退出所选进程", target: self, action: #selector(requestForceQuit))
        quitButton.isEnabled = false; forceButton.isEnabled = false
        quitButton.isHidden = !allowsTermination; forceButton.isHidden = !allowsTermination
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        var columns: [(String, String, CGFloat)] = [("name", "进程", 260), ("pid", "PID", 65)]
        switch mode {
        case .cpu: columns += [("cpu", "CPU %", 110), ("memory", "内存", 120), ("share", "内存占比", 100)]
        case .memory: columns += [("memory", "内存", 120), ("share", "内存占比", 100), ("cpu", "CPU %", 110)]
        case .energy: columns += [("energy", "CPU 能耗 W", 120), ("cpu", "CPU %", 100), ("wakeups", "唤醒/秒", 110)]
        }
        if compact {
            switch mode {
            case .cpu: columns = [("name", "进程", 260), ("cpu", "CPU %", 110), ("memory", "内存", 110)]
            case .memory: columns = [("name", "进程", 240), ("memory", "内存", 120), ("share", "内存占比", 120)]
            case .energy: columns = [("name", "进程", 240), ("energy", "CPU 能耗 W", 130), ("cpu", "CPU %", 110)]
            }
        }
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = id == "name" ? (compact ? 140 : 180) : 60
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: false)
            column.headerToolTip = id == "cpu" ? "单个核心满载为 100%，多核进程可超过 100%" : (id == "share" ? "占本机物理内存的比例" : nil)
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self
        table.rowHeight = 27; table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = compact ? .noColumnAutoresizing : .lastColumnOnlyAutoresizingStyle
        table.sortDescriptors = [NSSortDescriptor(key: mode.rawValue, ascending: false)]
        table.allowsMultipleSelection = false
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = !compact
        scroll.borderType = .bezelBorder
        for view in [search, quitButton!, forceButton!, scroll, status] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: leadingAnchor), search.topAnchor.constraint(equalTo: topAnchor), search.widthAnchor.constraint(equalToConstant: 240),
            forceButton.trailingAnchor.constraint(equalTo: trailingAnchor), forceButton.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            quitButton.trailingAnchor.constraint(equalTo: forceButton.leadingAnchor, constant: -8), quitButton.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 7), status.leadingAnchor.constraint(equalTo: leadingAnchor), status.trailingAnchor.constraint(equalTo: trailingAnchor), status.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ sample: DetailedSnapshot) { self.sample = sample; reload() }
    func clear() { sample = nil; reload() }
    override func layout() {
        super.layout()
        guard compact, let scroll = table.enclosingScrollView else { return }
        let available = scroll.contentSize.width - table.intercellSpacing.width * 3 - 2
        let widths: [CGFloat]
        switch mode {
        case .cpu: widths = [max(140, available - 200), 80, 120]
        case .memory: widths = [max(140, available - 215), 120, 95]
        case .energy: widths = [max(140, available - 210), 120, 90]
        }
        for (column, width) in zip(table.tableColumns, widths) where abs(column.width - width) > 0.5 { column.width = width }
    }

    static func sorted(_ values: [ProcessMetric], key: String, ascending: Bool) -> [ProcessMetric] {
        func value(_ row: ProcessMetric) -> Double? {
            switch key {
            case "cpu": return row.cpu
            case "memory", "share": return Double(row.memory)
            case "energy": return row.energyWatts
            case "wakeups": return row.wakeups
            default: return Double(row.identity.pid)
            }
        }
        return values.sorted {
            if key == "name", $0.name != $1.name { return ascending ? $0.name < $1.name : $0.name > $1.name }
            let a = value($0), b = value($1)
            if a == nil && b != nil { return false }
            if a != nil && b == nil { return true }
            if let a, let b, a != b { return ascending ? a < b : a > b }
            return $0.identity.pid < $1.identity.pid
        }
    }
    private var selected: ProcessMetric? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func reload() {
        let identity = selected?.identity
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = (sample?.processes ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.identity.pid).contains(query) }
        let descriptor = table.sortDescriptors.first
        rows = Self.sorted(filtered, key: descriptor?.key ?? mode.rawValue, ascending: descriptor?.ascending ?? false)
        table.reloadData()
        if let identity, let row = rows.firstIndex(where: { $0.identity == identity }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        updateSelection()
    }
    private func updateSelection() {
        let reason = allowsTermination ? selected.flatMap(ProcessActions.protectionReason) : nil
        quitButton.isEnabled = allowsTermination && selected != nil && reason == nil
        forceButton.isEnabled = quitButton.isEnabled
        let total = sample?.totalProcesses ?? 0, readable = sample?.processes.count ?? 0
        status.stringValue = "显示 \(rows.count) 项 · 可读取 \(readable) / \(total) 个进程" + (reason.map { " · \($0)不可退出" } ?? "")
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let value = rows[row]
        let cell = (table.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = id
        if cell.textField == nil {
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.usesSingleLineMode = true
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let field = cell.textField!
        field.font = id.rawValue == "name" ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = id.rawValue == "name" ? .left : .right
        switch id.rawValue {
        case "name": field.stringValue = value.name
        case "pid": field.stringValue = String(value.identity.pid)
        case "cpu": field.stringValue = value.cpu.map { String(format: "%.1f", $0) } ?? "--"
        case "memory": field.stringValue = memorySize(Double(value.memory))
        case "share": field.stringValue = String(format: "%.1f%%", value.memoryPercent)
        case "energy": field.stringValue = sample?.energyAvailable == true ? (value.energyWatts.map { String(format: "%.3f", $0) } ?? "--") : "--"
        case "wakeups": field.stringValue = value.wakeups.map { String(format: "%.1f", $0) } ?? "--"
        default: break
        }
        field.toolTip = id.rawValue == "name" ? value.path : field.stringValue
        return cell
    }
    @objc private func requestQuit() { confirmTermination(force: false) }
    @objc private func requestForceQuit() { confirmTermination(force: true) }
    private func confirmTermination(force: Bool) {
        guard allowsTermination, let process = selected, ProcessActions.protectionReason(process) == nil, let window else { return }
        let alert = NSAlert()
        alert.messageText = "\(force ? "强制退出" : "退出")“\(process.name)”？"
        alert.informativeText = "PID \(process.identity.pid)。" + (force ? "强制退出可能丢失未保存内容。" : "退出前请保存正在编辑的内容。")
        alert.addButton(withTitle: force ? "强制退出" : "退出")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do { try ProcessActions.terminate(process, force: force) }
            catch { if let window = self?.window { NSAlert(error: error).beginSheetModal(for: window) } }
        }
    }
}

final class DiskUsageView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "尚未扫描")
    private var scanButton: NSButton!
    private var cancelButton: NSButton!
    private(set) var root = FileManager.default.homeDirectoryForCurrentUser
    private(set) var result: DiskScanResult?
    private(set) var rows: [DiskUsageItem] = []
    private var cancellation: DiskScanCancellation?
    private var generation = UUID()
    private let queue = DispatchQueue(label: "local.macpulse.disk-scan", qos: .utility)
    var onChooseFolder: (() -> Void)?
    private let compact: Bool

    init(compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        let choose = toolButton("folder", "选择扫描目录", target: self, action: #selector(chooseFolder))
        let up = toolButton("arrow.up", "扫描上级目录", target: self, action: #selector(goUp))
        scanButton = toolButton("arrow.clockwise", "扫描当前目录", target: self, action: #selector(scanCurrent))
        cancelButton = toolButton("xmark", "取消扫描", target: self, action: #selector(cancelScan))
        cancelButton.isEnabled = false
        let reveal = toolButton("arrow.up.forward.square", "在 Finder 中显示所选项目", target: self, action: #selector(revealSelected))
        let tools = NSStackView(views: [choose, up, scanButton, cancelButton, reveal])
        tools.orientation = .horizontal; tools.spacing = 6
        pathLabel.lineBreakMode = .byTruncatingMiddle; pathLabel.font = .systemFont(ofSize: 12)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        for (id, title, width) in [("name", "项目", compact ? 230.0 : 390.0), ("bytes", "已分配容量", compact ? 120.0 : 150.0), ("share", "占已统计容量", 130.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = id == "name" ? (compact ? 140 : 200) : 120
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: false)
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 29
        table.usesAlternatingRowBackgroundColors = true
        if compact { table.columnAutoresizingStyle = .noColumnAutoresizing }
        status.lineBreakMode = .byTruncatingTail
        table.target = self; table.doubleAction = #selector(drillDown)
        table.sortDescriptors = [NSSortDescriptor(key: "bytes", ascending: false)]
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = !compact; scroll.borderType = .bezelBorder
        for view in [tools, pathLabel, scroll, status] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            tools.topAnchor.constraint(equalTo: topAnchor), tools.leadingAnchor.constraint(equalTo: leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 10), pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor), pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8), status.bottomAnchor.constraint(equalTo: bottomAnchor), status.leadingAnchor.constraint(equalTo: leadingAnchor), status.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        pathLabel.stringValue = root.path
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        guard compact, let scroll = table.enclosingScrollView else { return }
        let available = scroll.contentSize.width - table.intercellSpacing.width * 3 - 2
        for (column, width) in zip(table.tableColumns, [max(140, available - 240), 120, 120]) where abs(column.width - width) > 0.5 { column.width = width }
    }
    deinit { cancellation?.cancel() }
    func scan(_ directory: URL) {
        cancellation?.cancel()
        let cancellation = DiskScanCancellation(), token = UUID()
        self.cancellation = cancellation; generation = token; root = directory; result = nil; rows = []
        table.reloadData(); pathLabel.stringValue = directory.path; pathLabel.toolTip = directory.path
        status.stringValue = "扫描中…"; scanButton.isEnabled = false; cancelButton.isEnabled = true
        queue.async { [weak self] in
            let result = DiskUsageScanner.scan(root: directory, cancellation: cancellation) { progress in
                RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in if self?.generation == token { self?.update(progress) } }
            }
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in if self?.generation == token { self?.update(result) } }
        }
    }
    func update(_ result: DiskScanResult) {
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].url : nil
        self.result = result
        root = result.root; pathLabel.stringValue = root.path; pathLabel.toolTip = root.path
        let descriptor = table.sortDescriptors.first
        rows = result.items.sorted {
            if descriptor?.key == "name" { return descriptor?.ascending == true ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.url.lastPathComponent > $1.url.lastPathComponent }
            if $0.bytes == $1.bytes { return $0.url.lastPathComponent < $1.url.lastPathComponent }
            return descriptor?.ascending == true ? $0.bytes < $1.bytes : $0.bytes > $1.bytes
        }
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.url == selected }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        let state = result.cancelled ? "已取消，结果不完整" : (result.finished ? "扫描完成" : "扫描中…")
        status.stringValue = "\(state) · \(result.visited) 项 · \(memorySize(Double(result.total))) · \(result.skipped) 项无法访问或已跳过"
        scanButton.isEnabled = result.finished; cancelButton.isEnabled = !result.finished
        if result.finished { cancellation = nil }
    }
    func cancel() { cancellation?.cancel() }
    @objc private func scanCurrent() { scan(root) }
    @objc private func cancelScan() { cancel() }
    @objc private func goUp() { scan(root.deletingLastPathComponent()) }
    @objc private func chooseFolder() {
        if let onChooseFolder { onChooseFolder(); return }
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = root; panel.prompt = "扫描"
        panel.beginSheetModal(for: window) { [weak self] response in if response == .OK, let url = panel.url { self?.scan(url) } }
    }
    @objc private func drillDown() {
        guard rows.indices.contains(table.clickedRow) else { return }
        let row = rows[table.clickedRow]
        if row.isDirectory { scan(row.url) } else { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
    }
    @objc private func revealSelected() { if rows.indices.contains(table.selectedRow) { NSWorkspace.shared.activateFileViewerSelecting([rows[table.selectedRow].url]) } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { if let result { update(result) } }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let field = (table.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        field.identifier = id; field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle; field.alignment = id.rawValue == "name" ? .left : .right
        let item = rows[row]
        if id.rawValue == "name" { field.stringValue = item.url.lastPathComponent + (item.isDirectory ? "/" : "") }
        else if id.rawValue == "bytes" { field.stringValue = memorySize(Double(item.bytes)) }
        else { field.stringValue = (result?.total ?? 0) > 0 ? String(format: "%.1f%%", Double(item.bytes) / Double(result!.total) * 100) : "--" }
        field.toolTip = item.url.path
        return field
    }
}

final class ResourceDashboardView: NSView, NSTabViewDelegate {
    let tabs = NSTabView()
    private let navigation = NSSegmentedControl(labels: ["总览与设置", "CPU", "内存", "磁盘", "电池与能耗"], trackingMode: .selectOne, target: nil, action: nil)
    let cpuTable = ProcessTableView(mode: .cpu)
    let memoryTable = ProcessTableView(mode: .memory)
    let energyTable = ProcessTableView(mode: .energy)
    let disk = DiskUsageView()
    let cores = CoreUsageView()
    let overviewCores = CoreUsageView()
    private let memorySummary = NSTextField(wrappingLabelWithString: "等待内存采样")
    private let energySummary = NSTextField(wrappingLabelWithString: "等待电池信息")
    private let overviewSummary = NSTextField(wrappingLabelWithString: "等待采样")
    private var sample: MetricsSnapshot?
    private var details: DetailedSnapshot?

    init(configuration: ResourceMonitorContentView) {
        super.init(frame: NSRect(x: 0, y: 0, width: 860, height: 650))
        navigation.segmentStyle = .smallSquare
        navigation.target = self; navigation.action = #selector(selectPage)
        navigation.selectedSegment = 0
        tabs.tabViewType = .noTabsNoBorder; tabs.delegate = self
        for view in [navigation, tabs] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([navigation.centerXAnchor.constraint(equalTo: centerXAnchor), navigation.topAnchor.constraint(equalTo: topAnchor, constant: 12), navigation.heightAnchor.constraint(equalToConstant: 28), navigation.widthAnchor.constraint(equalToConstant: 580), tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), tabs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), tabs.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 12), tabs.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)])
        let overview = NSView()
        let coreTitle = NSTextField(labelWithString: "各核心 CPU 占用")
        coreTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let coreScroll = coreContainer(overviewCores)
        for view in [configuration, coreTitle, coreScroll, overviewSummary] { view.translatesAutoresizingMaskIntoConstraints = false; overview.addSubview(view) }
        NSLayoutConstraint.activate([
            configuration.leadingAnchor.constraint(equalTo: overview.leadingAnchor, constant: 8), configuration.topAnchor.constraint(equalTo: overview.topAnchor, constant: 8), configuration.widthAnchor.constraint(equalToConstant: 340), configuration.heightAnchor.constraint(equalToConstant: 454),
            coreTitle.leadingAnchor.constraint(equalTo: configuration.trailingAnchor, constant: 20), coreTitle.topAnchor.constraint(equalTo: overview.topAnchor, constant: 24),
            coreScroll.leadingAnchor.constraint(equalTo: coreTitle.leadingAnchor), coreScroll.trailingAnchor.constraint(equalTo: overview.trailingAnchor, constant: -16), coreScroll.topAnchor.constraint(equalTo: coreTitle.bottomAnchor, constant: 12), coreScroll.heightAnchor.constraint(equalToConstant: 200),
            overviewSummary.leadingAnchor.constraint(equalTo: coreTitle.leadingAnchor), overviewSummary.trailingAnchor.constraint(equalTo: coreScroll.trailingAnchor), overviewSummary.topAnchor.constraint(equalTo: coreScroll.bottomAnchor, constant: 20)
        ])
        addTab("总览与设置", view: overview)
        addTab("CPU", view: page(header: coreContainer(cores), height: 150, body: cpuTable))
        addTab("内存", view: page(header: memorySummary, height: 60, body: memoryTable))
        let diskPage = page(header: NSTextField(labelWithString: "目录容量"), height: 20, body: disk)
        addTab("磁盘", view: diskPage)
        addTab("电池与能耗", view: page(header: energySummary, height: 80, body: energyTable))
        for label in [memorySummary, energySummary, overviewSummary] { label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func selectPage() { tabs.selectTabViewItem(at: navigation.selectedSegment) }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if let tabViewItem { navigation.selectedSegment = tabView.indexOfTabViewItem(tabViewItem) }
    }
    private func addTab(_ label: String, view: NSView) {
        let tab = NSTabViewItem(identifier: label); tab.label = label; tab.view = view; tabs.addTabViewItem(tab)
    }
    private func coreContainer(_ view: CoreUsageView) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = view; view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), view.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), view.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)])
        return scroll
    }
    private func page(header: NSView, height: CGFloat, body: NSView) -> NSView {
        let page = NSView()
        for view in [header, body] { view.translatesAutoresizingMaskIntoConstraints = false; page.addSubview(view) }
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -14), header.topAnchor.constraint(equalTo: page.topAnchor, constant: 14), header.heightAnchor.constraint(equalToConstant: height), body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), body.leadingAnchor.constraint(equalTo: header.leadingAnchor), body.trailingAnchor.constraint(equalTo: header.trailingAnchor), body.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -12)])
        return page
    }
    func update(_ sample: MetricsSnapshot) { self.sample = sample; updateSummaries() }
    func updateDetails(_ details: DetailedSnapshot) {
        self.details = details
        cores.update(details.cores); overviewCores.update(details.cores)
        cpuTable.update(details); memoryTable.update(details); energyTable.update(details)
        updateSummaries()
    }
    private func updateSummaries() {
        if let memory = sample?.memory {
            memorySummary.stringValue = "内存 \(MenuBarText.percent(memory.percent)) · 已用 \(memorySize(memory.occupied)) / \(memorySize(memory.total)) · \(memory.pressureLabel)\n应用 \(memorySize(memory.application ?? 0)) · 固定 \(memorySize(memory.wired ?? 0)) · 压缩 \(memorySize(memory.compressed)) · 交换 \(memorySize(memory.swap ?? 0))"
        }
        let battery = details == nil ? "正在读取电池信息" : (details?.battery?.summary ?? "无内置电池 · 外接电源")
        let watts = sample.flatMap(MenuBarText.freshPower).map { String(format: "供电侧 %.1f W", $0.watts) } ?? "供电功率暂无数据"
        let energy = details?.energyAvailable == true ? "进程 CPU 能耗估算，不含 GPU、磁盘及显示器。" : "当前系统未提供进程能耗数据，可在 CPU 栏查看活跃进程。"
        energySummary.stringValue = "\(battery)\n\(watts)\n\(energy)"
        overviewSummary.stringValue = "\(battery)\n\n\(watts)\n\n\(memorySummary.stringValue)"
    }
}
