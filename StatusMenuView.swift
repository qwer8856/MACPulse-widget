import AppKit

final class StatusMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    let header = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 32))
    private let timestamp = NSTextField(labelWithString: "--:--:--")
    private let pressure = NSTextField(labelWithString: "压力未知")
    private let options = StatusMenuOptionsView()
    private(set) var items: [StatusDetail: NSMenuItem] = [:]
    private(set) var panels: [StatusDetail: StatusDetailView] = [:]
    private var snapshot: MetricsSnapshot?
    private var battery: BatteryMetric?
    private var hasBatterySample = false
    private var batterySymbol = StatusDetail.battery.symbol
    private var highlightTimer: Timer?
    var view: NSView { options }
    var toggles: [NSButton] { options.toggles }
    var cores: CoreUsageView { panels[.cpu]!.cores }
    var onSelection: ((Set<MenuBarMetric>) -> Void)?
    var onOpenMonitor: ((Int) -> Void)?
    var onDisable: (() -> Void)?
    var onQuit: (() -> Void)?
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"; return formatter
    }()

    override init() {
        super.init()
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
            submenu.delegate = self
            submenu.autoenablesItems = false
            let panel = StatusDetailView(kind: kind)
            panel.onOpenMonitor = { [weak self] page in self?.menu.cancelTracking(); self?.onOpenMonitor?(page) }
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
        options.updateBatteryAvailability(nil)
    }
    func updateSelection(_ selected: Set<MenuBarMetric>) { options.updateSelection(selected) }
    func highlight(_ item: NSMenuItem?) {
        highlightTimer?.invalidate()
        guard let item, let kind = items.first(where: { $0.value === item })?.key else { return }
        var attempts = 0
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self, weak item] timer in
            guard let self, let item, self.menu.highlightedItem === item,
                  self.panels[kind]?.window?.isVisible != true else { timer.invalidate(); return }
            // Invoke our own menu item's public action without a global event monitor or system preference change.
            _ = item.accessibilityPerformPress()
            attempts += 1
            if attempts == 4 { timer.invalidate() }
        }
        highlightTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    func endTracking() {
        highlightTimer?.invalidate(); highlightTimer = nil
        panels.values.forEach { $0.endPresentation() }
    }
    func menuWillOpen(_ menu: NSMenu) {
        highlightTimer?.invalidate(); highlightTimer = nil
        for kind in StatusDetail.allCases where items[kind]?.submenu === menu { panels[kind]?.prepareForPresentation() }
    }
    func menuDidClose(_ menu: NSMenu) {
        for kind in StatusDetail.allCases where items[kind]?.submenu === menu { panels[kind]?.endPresentation() }
    }
    deinit { highlightTimer?.invalidate() }
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
        if let details { updateBattery(details.battery) }
        panels.values.forEach { $0.updateDetails(details) }
        updateRows()
    }
    func updateBattery(_ battery: BatteryMetric?) {
        self.battery = battery
        hasBatterySample = true
        options.updateBatteryAvailability(battery != nil)
        let symbol = battery?.symbol ?? StatusDetail.battery.symbol
        if symbol != batterySymbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "电池")?.withSymbolConfiguration(.preferringMonochrome())
            image?.size = NSSize(width: 15, height: 15)
            items[.battery]?.image = image
            batterySymbol = symbol
        }
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
                value = battery.map { MenuBarText.percent($0.percent) } ?? (hasBatterySample ? "无电池" : "--")
                detail = hasBatterySample ? (battery?.stateLabel ?? "无内置电池 · 外接电源") : "正在读取电池信息"
            }
            // Render both lines together: AppKit can drop a separate subtitle when an attributed title changes during tracking.
            let title = NSMutableAttributedString(string: kind.title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            title.append(NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 11)]))
            if items[kind]?.attributedTitle != title { items[kind]?.attributedTitle = title }
            if items[kind]?.badge?.stringValue != value { items[kind]?.badge = NSMenuItemBadge(string: value) }
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
    func updateBatteryAvailability(_ available: Bool?) {
        guard let index = MenuBarMetric.allCases.firstIndex(of: .battery) else { return }
        toggles[index].isEnabled = available == true
        toggles[index].toolTip = available == nil ? "正在读取电池信息" : (available == true ? "显示电池图标和剩余电量" : "此 Mac 无内置电池")
    }
    @objc private func changeSelection() { onSelection?(Set(MenuBarMetric.allCases.enumerated().compactMap { toggles[$0.offset].state == .on ? $0.element : nil })) }
    @objc private func openMonitor() { onOpenMonitor?() }
    @objc private func disable() { onDisable?() }
    @objc private func quit() { onQuit?() }
}
