import AppKit
import ServiceManagement

enum MenuBarMetric: String, CaseIterable {
    case cpu, memory, disk, power, battery

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .disk: return "磁盘"
        case .power: return "功率"
        case .battery: return "电池"
        }
    }

    static func title(for metrics: Set<MenuBarMetric>, snapshot: MetricsSnapshot?, battery: BatteryMetric? = nil) -> String {
        allCases.filter { metrics.contains($0) }.map { $0.title(snapshot, battery: battery) }.joined(separator: "  ")
    }

    static func attributedTitle(for metrics: Set<MenuBarMetric>, snapshot: MetricsSnapshot?, battery: BatteryMetric?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for metric in allCases where metrics.contains(metric) {
            if result.length > 0 { result.append(NSAttributedString(string: "  ")) }
            if metric == .battery, let battery,
               let image = NSImage(systemSymbolName: battery.symbol, accessibilityDescription: battery.summary)?.withSymbolConfiguration(.preferringMonochrome()) {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: (font.capHeight - 11) / 2, width: 21, height: 11)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " " + MenuBarText.percent(battery.percent)))
            } else {
                result.append(NSAttributedString(string: metric.title(snapshot, battery: battery)))
            }
        }
        result.addAttributes([.font: font], range: NSRange(location: 0, length: result.length))
        return result
    }

    static func width(for metrics: Set<MenuBarMetric>) -> CGFloat {
        guard !metrics.isEmpty else { return NSStatusItem.squareLength }
        // Reserve the widest valid readings so sampling never shifts nearby menu items.
        let maximum = allCases.filter { metrics.contains($0) }.map {
            $0.label + ($0 == .power ? " 1000.0 W" : " 100%")
        }.joined(separator: "  ")
        return ceil((maximum as NSString).size(withAttributes: [.font: font]).width) + 34
    }

    func title(_ snapshot: MetricsSnapshot?, battery: BatteryMetric? = nil) -> String {
        switch self {
        case .cpu: return "CPU \(MenuBarText.percent(snapshot?.cpu))"
        case .memory: return "内存 \(MenuBarText.percent(snapshot?.memory?.percent))"
        case .disk: return "磁盘 \(MenuBarText.percent(snapshot?.disk?.percent))"
        case .power:
            let power = snapshot.flatMap { MenuBarText.freshPower($0) }
            return "功率 " + (power.map { String(format: "%.1f W", $0.watts) } ?? "--")
        case .battery: return "电池 " + MenuBarText.percent(battery?.percent)
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

    var menuBarStyle: MenuBarStyle {
        get { defaults.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init(rawValue:)) ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: "menuBarStyle") }
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
    let updates = UpdateStatusView(frame: .zero)
    let metricsView = MenuBarContentView()
    let menuBarToggle = NSButton(checkboxWithTitle: "在菜单栏显示", target: nil, action: nil)
    let metricToggles = MenuBarMetric.allCases.map { NSButton(checkboxWithTitle: $0.label, target: nil, action: nil) }
    let stylePicker = MenuBarStylePicker()
    let loginItemToggle = NSButton(checkboxWithTitle: "登录时自动启动", target: nil, action: nil)
    var onMenuBarChanged: ((Bool) -> Void)?
    var onMetricsChanged: ((Set<MenuBarMetric>) -> Void)?
    var onStyleChanged: ((MenuBarStyle) -> Void)?
    var onLoginItemToggle: (() -> Void)?
    var onLoginItemSettings: (() -> Void)?
    var onActivityMonitor: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 406))
        let separator = NSBox()
        separator.boxType = .separator
        let settingsTitle = NSTextField(labelWithString: "显示与启动")
        settingsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let loginSeparator = NSBox()
        loginSeparator.boxType = .separator
        let toolsTitle = NSTextField(labelWithString: "系统工具")
        toolsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let label = NSTextField(labelWithString: "显示内容")
        label.font = .systemFont(ofSize: 12)
        let styleLabel = NSTextField(labelWithString: "菜单栏样式")
        styleLabel.font = .systemFont(ofSize: 12)
        stylePicker.onChange = { [weak self] in self?.onStyleChanged?($0) }
        let choices = NSStackView(views: metricToggles)
        choices.orientation = .horizontal
        choices.distribution = .fillEqually
        choices.alignment = .centerY
        choices.spacing = 4
        for toggle in metricToggles {
            toggle.target = self
            toggle.action = #selector(changeMetrics)
        }
        menuBarToggle.target = self
        menuBarToggle.action = #selector(changeMenuBar)
        loginItemToggle.target = self
        loginItemToggle.action = #selector(changeLoginItem)
        loginItemToggle.allowsMixedState = true
        let loginSettings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "登录项设置")!, target: self, action: #selector(openLoginSettings))
        loginSettings.bezelStyle = .rounded
        loginSettings.toolTip = "打开系统登录项设置"
        let activity = NSButton(title: "活动监视器", target: self, action: #selector(openActivity))
        activity.bezelStyle = .rounded
        activity.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        activity.imagePosition = .imageLeading
        for view in [metricsView, separator, settingsTitle, menuBarToggle, label, choices, styleLabel, stylePicker, loginSeparator, loginItemToggle, loginSettings, toolsTitle, activity, updates] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            metricsView.topAnchor.constraint(equalTo: topAnchor),
            metricsView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metricsView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5, constant: -20),
            metricsView.heightAnchor.constraint(equalToConstant: 342),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            separator.centerXAnchor.constraint(equalTo: centerXAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.bottomAnchor.constraint(equalTo: metricsView.bottomAnchor, constant: -12),
            settingsTitle.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 24),
            settingsTitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            settingsTitle.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            menuBarToggle.topAnchor.constraint(equalTo: settingsTitle.bottomAnchor, constant: 16),
            menuBarToggle.leadingAnchor.constraint(equalTo: settingsTitle.leadingAnchor),
            label.leadingAnchor.constraint(equalTo: settingsTitle.leadingAnchor),
            label.topAnchor.constraint(equalTo: menuBarToggle.bottomAnchor, constant: 12),
            choices.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            choices.leadingAnchor.constraint(equalTo: settingsTitle.leadingAnchor),
            choices.trailingAnchor.constraint(equalTo: settingsTitle.trailingAnchor),
            choices.heightAnchor.constraint(equalToConstant: 20),
            styleLabel.leadingAnchor.constraint(equalTo: settingsTitle.leadingAnchor),
            styleLabel.topAnchor.constraint(equalTo: choices.bottomAnchor, constant: 12),
            stylePicker.topAnchor.constraint(equalTo: styleLabel.bottomAnchor, constant: 6),
            stylePicker.leadingAnchor.constraint(equalTo: settingsTitle.leadingAnchor), stylePicker.trailingAnchor.constraint(equalTo: settingsTitle.trailingAnchor),
            stylePicker.heightAnchor.constraint(equalToConstant: 24),
            loginSeparator.topAnchor.constraint(equalTo: stylePicker.bottomAnchor, constant: 14),
            loginSeparator.leadingAnchor.constraint(equalTo: settingsTitle.leadingAnchor),
            loginSeparator.trailingAnchor.constraint(equalTo: settingsTitle.trailingAnchor),
            loginItemToggle.leadingAnchor.constraint(equalTo: settingsTitle.leadingAnchor),
            loginItemToggle.topAnchor.constraint(equalTo: loginSeparator.bottomAnchor, constant: 12),
            loginItemToggle.trailingAnchor.constraint(lessThanOrEqualTo: loginSettings.leadingAnchor, constant: -8),
            loginSettings.trailingAnchor.constraint(equalTo: settingsTitle.trailingAnchor),
            loginSettings.centerYAnchor.constraint(equalTo: loginItemToggle.centerYAnchor),
            loginSettings.widthAnchor.constraint(equalToConstant: 44),
            toolsTitle.leadingAnchor.constraint(equalTo: settingsTitle.leadingAnchor),
            toolsTitle.topAnchor.constraint(equalTo: loginItemToggle.bottomAnchor, constant: 20),
            activity.leadingAnchor.constraint(equalTo: settingsTitle.leadingAnchor),
            activity.topAnchor.constraint(equalTo: toolsTitle.bottomAnchor, constant: 10),
            updates.topAnchor.constraint(equalTo: activity.bottomAnchor, constant: 8),
            updates.leadingAnchor.constraint(equalTo: settingsTitle.leadingAnchor), updates.trailingAnchor.constraint(equalTo: settingsTitle.trailingAnchor),
            updates.heightAnchor.constraint(equalToConstant: 66), updates.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updatePreferences(_ preferences: MonitorPreferences) {
        menuBarToggle.state = preferences.menuBarEnabled ? .on : .off
        stylePicker.style = preferences.menuBarStyle
        for (index, metric) in MenuBarMetric.allCases.enumerated() {
            metricToggles[index].state = preferences.metrics.contains(metric) ? .on : .off
        }
    }

    func updateBatteryAvailability(_ available: Bool?) {
        guard let index = MenuBarMetric.allCases.firstIndex(of: .battery) else { return }
        metricToggles[index].isEnabled = available == true
        metricToggles[index].toolTip = available == nil ? "正在读取电池信息" : (available == true ? "显示电池图标和剩余电量" : "此 Mac 无内置电池")
    }

    func updateLoginItem(_ status: SMAppService.Status) {
        switch status {
        case .enabled:
            loginItemToggle.title = "登录时自动启动"
            loginItemToggle.state = .on
        case .requiresApproval:
            loginItemToggle.title = "登录时自动启动（待批准）"
            loginItemToggle.state = .mixed
        case .notRegistered, .notFound:
            loginItemToggle.title = "登录时自动启动"
            loginItemToggle.state = .off
        default:
            loginItemToggle.title = "登录时自动启动（不可用）"
            loginItemToggle.state = .off
        }
    }

    @objc private func changeMenuBar() { onMenuBarChanged?(menuBarToggle.state == .on) }
    @objc private func changeLoginItem() { onLoginItemToggle?() }
    @objc private func openLoginSettings() { onLoginItemSettings?() }
    @objc private func changeMetrics() {
        let selected = MenuBarMetric.allCases.enumerated().compactMap { index, metric in
            metricToggles[index].state == .on ? metric : nil
        }
        onMetricsChanged?(Set(selected))
    }
    @objc private func openActivity() { onActivityMonitor?() }
}
