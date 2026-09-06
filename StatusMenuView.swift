import AppKit

final class StatusMenuController {
    let menu = NSMenu()
    let header = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 32))
    private let timestamp = NSTextField(labelWithString: "--:--:--")
    private let pressure = NSTextField(labelWithString: "压力未知")
    private let options = StatusMenuOptionsView()
    private(set) var items: [StatusDetail: NSMenuItem] = [:]
    private(set) var panels: [StatusDetail: StatusDetailView] = [:]
    private var snapshot: MetricsSnapshot?
    private var details: DetailedSnapshot?
    var view: NSView { options }
    var toggles: [NSButton] { options.toggles }
    var cores: CoreUsageView { panels[.cpu]!.cores }
    var disk: DiskUsageView { panels[.disk]!.disk }
    var onSelection: ((Set<MenuBarMetric>) -> Void)?
    var onOpenMonitor: ((Int) -> Void)?
    var onDisable: (() -> Void)?
    var onQuit: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"; return formatter
    }()

    init() {
        menu.minimumWidth = 380; menu.autoenablesItems = false
        let title = NSTextField(labelWithString: "系统状态")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        timestamp.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timestamp.textColor = .secondaryLabelColor
        for field in [title, timestamp] { field.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(field) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14), title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            timestamp.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14), timestamp.centerYAnchor.constraint(equalTo: title.centerYAnchor)
        ])
        let heading = NSMenuItem(); heading.view = header; heading.isEnabled = false; menu.addItem(heading)
        for kind in StatusDetail.allCases {
            let item = NSMenuItem(title: kind.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)
            item.image?.size = NSSize(width: 15, height: 15)
            let submenu = NSMenu(title: kind.title)
            submenu.autoenablesItems = false
            let panel = StatusDetailView(kind: kind)
            panel.onOpenMonitor = { [weak self] page in self?.menu.cancelTracking(); self?.onOpenMonitor?(page) }
            if kind == .disk { panel.disk.onChooseFolder = { [weak self] in self?.menu.cancelTracking(); self?.onChooseFolder?() } }
            let content = NSMenuItem(); content.view = panel; submenu.addItem(content)
            item.submenu = submenu; items[kind] = item; panels[kind] = panel; menu.addItem(item)
        }
        menu.addItem(.separator())
        let pressureView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        pressure.font = .systemFont(ofSize: 11, weight: .medium)
        pressure.translatesAutoresizingMaskIntoConstraints = false; pressureView.addSubview(pressure)
        NSLayoutConstraint.activate([pressure.leadingAnchor.constraint(equalTo: pressureView.leadingAnchor, constant: 14), pressure.trailingAnchor.constraint(equalTo: pressureView.trailingAnchor, constant: -14), pressure.centerYAnchor.constraint(equalTo: pressureView.centerYAnchor)])
        let pressureItem = NSMenuItem(); pressureItem.view = pressureView; pressureItem.isEnabled = false; menu.addItem(pressureItem)
        let footer = NSMenuItem(); footer.view = options; menu.addItem(footer)
        options.onSelection = { [weak self] in self?.onSelection?($0) }
        options.onOpenMonitor = { [weak self] in self?.menu.cancelTracking(); self?.onOpenMonitor?(0) }
        options.onDisable = { [weak self] in self?.menu.cancelTracking(); self?.onDisable?() }
        options.onQuit = { [weak self] in self?.menu.cancelTracking(); self?.onQuit?() }
        updateRows()
    }
    func updateSelection(_ selected: Set<MenuBarMetric>) { options.updateSelection(selected) }
    func update(_ snapshot: MetricsSnapshot) {
        self.snapshot = snapshot
        timestamp.stringValue = timeFormatter.string(from: snapshot.sampledAt)
        pressure.stringValue = (snapshot.memory?.pressureLabel ?? "压力未知") + (snapshot.memory?.swap.map { " · 交换 " + memorySize($0) } ?? "")
        switch snapshot.memory?.pressure {
        case 1: pressure.textColor = .systemGreen
        case 2: pressure.textColor = .systemOrange
        case 4: pressure.textColor = .systemRed
        default: pressure.textColor = .secondaryLabelColor
        }
        panels.values.forEach { $0.update(snapshot) }
        updateRows()
    }
    func updateDetails(_ details: DetailedSnapshot?) {
        self.details = details
        panels.values.forEach { $0.updateDetails(details) }
        updateRows()
    }
    private func updateRows() {
        for kind in StatusDetail.allCases {
            let value: String, detail: String
            switch kind {
            case .cpu:
                value = MenuBarText.percent(snapshot?.cpu)
                detail = "\(ProcessInfo.processInfo.processorCount) 个逻辑核心"
            case .memory:
                value = MenuBarText.percent(snapshot?.memory?.percent)
                detail = snapshot?.memory.map { "已用 " + memorySize($0.occupied) + " / " + memorySize($0.total) } ?? "等待采样"
            case .disk:
                value = MenuBarText.percent(snapshot?.disk?.percent)
                detail = snapshot?.disk.map { String(format: "可用 %.1f / %.1f GB", $0.free / 1e9, $0.total / 1e9) } ?? "等待采样"
            case .power:
                value = snapshot.flatMap(MenuBarText.freshPower).map { String(format: "%.1f W", $0.watts) } ?? "--"
                detail = "供电侧估算"
            case .battery:
                value = details?.battery.map { MenuBarText.percent($0.percent) } ?? (details == nil ? "--" : "无电池")
                detail = details == nil ? "正在读取电池信息" : (details?.battery.map { $0.charging ? "正在充电" : ($0.external ? "外接电源" : "电池供电") } ?? "无内置电池 · 外接电源")
            }
            let text = kind.title + "\t" + value
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 285)]
            items[kind]?.title = kind.title + " " + value
            items[kind]?.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .paragraphStyle: paragraph])
            if #available(macOS 14.4, *) { items[kind]?.subtitle = detail }
            items[kind]?.toolTip = detail
        }
    }
}

private final class StatusMenuOptionsView: NSView {
    let toggles = MenuBarMetric.allCases.map { NSButton(checkboxWithTitle: $0.label, target: nil, action: nil) }
    var onSelection: ((Set<MenuBarMetric>) -> Void)?
    var onOpenMonitor: (() -> Void)?
    var onDisable: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 116))
        let label = NSTextField(labelWithString: "显示内容")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        let choices = NSStackView(views: toggles)
        choices.orientation = .horizontal; choices.distribution = .fillEqually; choices.spacing = 8
        for toggle in toggles { toggle.target = self; toggle.action = #selector(changeSelection) }
        let open = NSButton(title: "资源监视", target: self, action: #selector(openMonitor))
        open.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)
        open.imagePosition = .imageLeading; open.bezelStyle = .rounded
        let hide = tool("eye.slash", "关闭菜单栏显示", #selector(disable))
        let quit = tool("power", "退出系统状态", #selector(quit))
        let commands = NSStackView(views: [open, hide, quit])
        commands.orientation = .horizontal; commands.spacing = 8
        for view in [label, choices, commands] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            choices.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10), choices.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            choices.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), choices.heightAnchor.constraint(equalToConstant: 22),
            commands.topAnchor.constraint(equalTo: choices.bottomAnchor, constant: 16), commands.leadingAnchor.constraint(equalTo: label.leadingAnchor), commands.trailingAnchor.constraint(equalTo: choices.trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    private func tool(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!, target: self, action: action)
        button.bezelStyle = .rounded; button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 38).isActive = true
        return button
    }
    func updateSelection(_ selected: Set<MenuBarMetric>) {
        for (index, metric) in MenuBarMetric.allCases.enumerated() { toggles[index].state = selected.contains(metric) ? .on : .off }
    }
    @objc private func changeSelection() { onSelection?(Set(MenuBarMetric.allCases.enumerated().compactMap { toggles[$0.offset].state == .on ? $0.element : nil })) }
    @objc private func openMonitor() { onOpenMonitor?() }
    @objc private func disable() { onDisable?() }
    @objc private func quit() { onQuit?() }
}
