import AppKit

enum MenuBarMetric: String, CaseIterable {
    case cpu, memory, disk, power

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .disk: return "磁盘"
        case .power: return "功率"
        }
    }

    static func title(for metrics: Set<MenuBarMetric>, snapshot: MetricsSnapshot?) -> String {
        allCases.filter { metrics.contains($0) }.map { $0.title(snapshot) }.joined(separator: "  ")
    }

    static func width(for metrics: Set<MenuBarMetric>) -> CGFloat {
        guard !metrics.isEmpty else { return NSStatusItem.squareLength }
        // Reserve the widest valid readings so sampling never shifts nearby menu items.
        let maximum = allCases.filter { metrics.contains($0) }.map {
            $0.label + ($0 == .power ? " 1000.0 W" : " 100%")
        }.joined(separator: "  ")
        return ceil((maximum as NSString).size(withAttributes: [.font: font]).width) + 34
    }

    func title(_ snapshot: MetricsSnapshot?) -> String {
        switch self {
        case .cpu: return "CPU \(MenuBarText.percent(snapshot?.cpu))"
        case .memory: return "内存 \(MenuBarText.percent(snapshot?.memory?.percent))"
        case .disk: return "磁盘 \(MenuBarText.percent(snapshot?.disk?.percent))"
        case .power:
            let power = snapshot.flatMap { MenuBarText.freshPower($0) }
            return "功率 " + (power.map { String(format: "%.1f W", $0.watts) } ?? "--")
        }
    }
}

final class MonitorPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var menuBarEnabled: Bool {
        get { defaults.bool(forKey: "menuBarEnabled") }
        set { defaults.set(newValue, forKey: "menuBarEnabled") }
    }

    var metrics: Set<MenuBarMetric> {
        get {
            if let stored = defaults.stringArray(forKey: "menuBarMetrics") {
                return Set(stored.compactMap(MenuBarMetric.init(rawValue:)))
            }
            // Preserve the single selection when upgrading from 2.2.0.
            let legacy = defaults.string(forKey: "menuBarMetric") ?? "cpuAndMemory"
            if legacy == "icon" { return [] }
            if let metric = MenuBarMetric(rawValue: legacy) { return [metric] }
            return [.cpu, .memory]
        }
        set {
            defaults.set(MenuBarMetric.allCases.filter { newValue.contains($0) }.map(\.rawValue), forKey: "menuBarMetrics")
        }
    }
}

final class ResourceMonitorContentView: NSView {
    let metricsView = MenuBarContentView()
    let menuBarToggle = NSButton(checkboxWithTitle: "在菜单栏显示", target: nil, action: nil)
    let metricToggles = MenuBarMetric.allCases.map { NSButton(checkboxWithTitle: $0.label, target: nil, action: nil) }
    var onMenuBarChanged: ((Bool) -> Void)?
    var onMetricsChanged: ((Set<MenuBarMetric>) -> Void)?
    var onActivityMonitor: (() -> Void)?
    var onRefreshWidgets: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 414))
        let separator = NSBox()
        separator.boxType = .separator
        let label = NSTextField(labelWithString: "显示内容")
        label.font = .systemFont(ofSize: 12)
        let choices = NSStackView(views: metricToggles)
        choices.orientation = .horizontal
        choices.distribution = .fillEqually
        choices.alignment = .centerY
        choices.spacing = 10
        for toggle in metricToggles {
            toggle.target = self
            toggle.action = #selector(changeMetrics)
        }
        menuBarToggle.target = self
        menuBarToggle.action = #selector(changeMenuBar)
        let activity = NSButton(title: "活动监视器", target: self, action: #selector(openActivity))
        activity.bezelStyle = .rounded
        activity.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        activity.imagePosition = .imageLeading
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新桌面小组件")!, target: self, action: #selector(refreshWidgets))
        refresh.bezelStyle = .rounded
        refresh.toolTip = "请求刷新桌面小组件"
        for view in [metricsView, separator, menuBarToggle, label, choices, activity, refresh] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            metricsView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            metricsView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            metricsView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            metricsView.heightAnchor.constraint(equalToConstant: 244),
            separator.topAnchor.constraint(equalTo: metricsView.bottomAnchor, constant: 4),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            menuBarToggle.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
            menuBarToggle.leadingAnchor.constraint(equalTo: separator.leadingAnchor),
            label.leadingAnchor.constraint(equalTo: separator.leadingAnchor),
            label.topAnchor.constraint(equalTo: menuBarToggle.bottomAnchor, constant: 14),
            choices.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            choices.leadingAnchor.constraint(equalTo: separator.leadingAnchor),
            choices.trailingAnchor.constraint(equalTo: separator.trailingAnchor),
            choices.heightAnchor.constraint(equalToConstant: 20),
            activity.leadingAnchor.constraint(equalTo: separator.leadingAnchor),
            activity.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            refresh.trailingAnchor.constraint(equalTo: separator.trailingAnchor),
            refresh.centerYAnchor.constraint(equalTo: activity.centerYAnchor),
            refresh.widthAnchor.constraint(equalToConstant: 36)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updatePreferences(_ preferences: MonitorPreferences) {
        menuBarToggle.state = preferences.menuBarEnabled ? .on : .off
        for (index, metric) in MenuBarMetric.allCases.enumerated() {
            metricToggles[index].state = preferences.metrics.contains(metric) ? .on : .off
        }
    }

    @objc private func changeMenuBar() { onMenuBarChanged?(menuBarToggle.state == .on) }
    @objc private func changeMetrics() {
        let selected = MenuBarMetric.allCases.enumerated().compactMap { index, metric in
            metricToggles[index].state == .on ? metric : nil
        }
        onMetricsChanged?(Set(selected))
    }
    @objc private func openActivity() { onActivityMonitor?() }
    @objc private func refreshWidgets() { onRefreshWidgets?() }
}
