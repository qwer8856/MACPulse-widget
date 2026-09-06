import AppKit

final class StatusMenuView: NSView {
    let metrics = MenuBarContentView()
    let cores = CoreUsageView()
    private let battery = NSTextField(wrappingLabelWithString: "正在读取电池信息")
    let toggles = MenuBarMetric.allCases.map { NSButton(checkboxWithTitle: $0.label, target: nil, action: nil) }
    var onSelection: ((Set<MenuBarMetric>) -> Void)?
    var onOpenMonitor: (() -> Void)?
    var onDisable: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 604))
        let coreTitle = NSTextField(labelWithString: "各核心 CPU 占用")
        coreTitle.font = .systemFont(ofSize: 12, weight: .medium)
        let coreScroll = NSScrollView()
        coreScroll.hasVerticalScroller = true; coreScroll.drawsBackground = false
        coreScroll.documentView = cores
        cores.translatesAutoresizingMaskIntoConstraints = false
        cores.update(Array(repeating: nil, count: ProcessInfo.processInfo.processorCount))
        let batteryTitle = NSTextField(labelWithString: "电池")
        batteryTitle.font = .systemFont(ofSize: 12, weight: .medium)
        battery.font = .systemFont(ofSize: 11)
        battery.textColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "显示内容")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        let choices = NSStackView(views: toggles)
        choices.orientation = .horizontal
        choices.distribution = .fillEqually
        choices.spacing = 8
        for toggle in toggles { toggle.target = self; toggle.action = #selector(changeSelection) }
        let open = NSButton(title: "资源监视", target: self, action: #selector(openMonitor))
        open.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)
        open.imagePosition = .imageLeading
        open.bezelStyle = .rounded
        let hide = tool("eye.slash", "关闭菜单栏显示", #selector(disable))
        let quit = tool("power", "退出系统状态", #selector(quit))
        let commands = NSStackView(views: [open, hide, quit])
        commands.orientation = .horizontal
        commands.spacing = 8
        for view in [metrics, coreTitle, coreScroll, batteryTitle, battery, label, choices, commands] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            metrics.topAnchor.constraint(equalTo: topAnchor), metrics.leadingAnchor.constraint(equalTo: leadingAnchor),
            metrics.trailingAnchor.constraint(equalTo: trailingAnchor), metrics.heightAnchor.constraint(equalToConstant: 244),
            coreTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), coreTitle.topAnchor.constraint(equalTo: metrics.bottomAnchor, constant: 4),
            coreScroll.leadingAnchor.constraint(equalTo: coreTitle.leadingAnchor), coreScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            coreScroll.topAnchor.constraint(equalTo: coreTitle.bottomAnchor, constant: 8), coreScroll.heightAnchor.constraint(equalToConstant: 128),
            cores.leadingAnchor.constraint(equalTo: coreScroll.contentView.leadingAnchor), cores.trailingAnchor.constraint(equalTo: coreScroll.contentView.trailingAnchor), cores.topAnchor.constraint(equalTo: coreScroll.contentView.topAnchor),
            batteryTitle.leadingAnchor.constraint(equalTo: coreTitle.leadingAnchor), batteryTitle.topAnchor.constraint(equalTo: coreScroll.bottomAnchor, constant: 12),
            battery.leadingAnchor.constraint(equalTo: coreTitle.leadingAnchor), battery.trailingAnchor.constraint(equalTo: coreScroll.trailingAnchor),
            battery.topAnchor.constraint(equalTo: batteryTitle.bottomAnchor, constant: 6), battery.heightAnchor.constraint(equalToConstant: 42),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), label.topAnchor.constraint(equalTo: battery.bottomAnchor, constant: 8),
            choices.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10), choices.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            choices.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), choices.heightAnchor.constraint(equalToConstant: 22),
            commands.topAnchor.constraint(equalTo: choices.bottomAnchor, constant: 20), commands.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            commands.trailingAnchor.constraint(equalTo: choices.trailingAnchor)
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
    func updateDetails(_ details: DetailedSnapshot?) {
        cores.update(details?.cores ?? Array(repeating: nil, count: ProcessInfo.processInfo.processorCount))
        battery.stringValue = details == nil ? "正在读取电池信息" : (details?.battery?.summary ?? "无内置电池 · 外接电源")
        battery.toolTip = battery.stringValue
    }
    @objc private func changeSelection() {
        onSelection?(Set(MenuBarMetric.allCases.enumerated().compactMap { toggles[$0.offset].state == .on ? $0.element : nil }))
    }
    @objc private func openMonitor() { enclosingMenuItem?.menu?.cancelTracking(); onOpenMonitor?() }
    @objc private func disable() { enclosingMenuItem?.menu?.cancelTracking(); onDisable?() }
    @objc private func quit() { enclosingMenuItem?.menu?.cancelTracking(); onQuit?() }
}
