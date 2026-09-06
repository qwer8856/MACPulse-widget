import AppKit

enum MenuBarMetric: String, CaseIterable {
    case cpuAndMemory, cpu, memory, disk, power, icon

    var label: String {
        switch self {
        case .cpuAndMemory: return "CPU 和内存"
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .disk: return "磁盘"
        case .power: return "功率"
        case .icon: return "仅图标"
        }
    }

    var width: CGFloat {
        switch self {
        case .cpuAndMemory: return 156
        case .power: return 116
        case .icon: return NSStatusItem.squareLength
        default: return 104
        }
    }

    func title(_ snapshot: MetricsSnapshot?) -> String {
        switch self {
        case .cpuAndMemory: return MenuBarText.title(snapshot)
        case .cpu: return "CPU \(MenuBarText.percent(snapshot?.cpu))"
        case .memory: return "内存 \(MenuBarText.percent(snapshot?.memory?.percent))"
        case .disk: return "磁盘 \(MenuBarText.percent(snapshot?.disk?.percent))"
        case .power:
            let power = snapshot.flatMap { MenuBarText.freshPower($0) }
            return "功率 " + (power.map { String(format: "%.1f W", $0.watts) } ?? "--")
        case .icon: return ""
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

    var metric: MenuBarMetric {
        get { MenuBarMetric(rawValue: defaults.string(forKey: "menuBarMetric") ?? "") ?? .cpuAndMemory }
        set { defaults.set(newValue.rawValue, forKey: "menuBarMetric") }
    }
}

final class ResourceMonitorContentView: NSView {
    let metricsView = MenuBarContentView()
    let menuBarToggle = NSButton(checkboxWithTitle: "在菜单栏显示", target: nil, action: nil)
    let metricPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    var onMenuBarChanged: ((Bool) -> Void)?
    var onMetricChanged: ((MenuBarMetric) -> Void)?
    var onActivityMonitor: (() -> Void)?
    var onRefreshWidgets: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 388))
        let separator = NSBox()
        separator.boxType = .separator
        let label = NSTextField(labelWithString: "显示内容")
        label.font = .systemFont(ofSize: 12)
        metricPicker.addItems(withTitles: MenuBarMetric.allCases.map(\.label))
        metricPicker.target = self
        metricPicker.action = #selector(changeMetric)
        menuBarToggle.target = self
        menuBarToggle.action = #selector(changeMenuBar)
        let activity = NSButton(title: "活动监视器", target: self, action: #selector(openActivity))
        activity.bezelStyle = .rounded
        activity.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        activity.imagePosition = .imageLeading
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新桌面小组件")!, target: self, action: #selector(refreshWidgets))
        refresh.bezelStyle = .rounded
        refresh.toolTip = "请求刷新桌面小组件"
        for view in [metricsView, separator, menuBarToggle, label, metricPicker, activity, refresh] {
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
            label.centerYAnchor.constraint(equalTo: metricPicker.centerYAnchor),
            metricPicker.topAnchor.constraint(equalTo: menuBarToggle.bottomAnchor, constant: 10),
            metricPicker.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 14),
            metricPicker.trailingAnchor.constraint(equalTo: separator.trailingAnchor),
            metricPicker.heightAnchor.constraint(equalToConstant: 25),
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
        metricPicker.selectItem(at: MenuBarMetric.allCases.firstIndex(of: preferences.metric)!)
    }

    @objc private func changeMenuBar() { onMenuBarChanged?(menuBarToggle.state == .on) }
    @objc private func changeMetric() { onMetricChanged?(MenuBarMetric.allCases[metricPicker.indexOfSelectedItem]) }
    @objc private func openActivity() { onActivityMonitor?() }
    @objc private func refreshWidgets() { onRefreshWidgets?() }
}
