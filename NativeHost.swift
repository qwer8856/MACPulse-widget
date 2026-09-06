import AppKit
import WidgetKit

final class NativeHostDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var statusItem: NSStatusItem?
    private(set) var window: NSWindow?
    private(set) var resourceView: ResourceMonitorContentView?
    private let preferences: MonitorPreferences
    private let monitor = LiveMetricsMonitor()
    private let metricsView = MenuBarContentView()
    private var snapshot: MetricsSnapshot?
    private var metricItems: [NSMenuItem] = []
    private var iconOnlyItem: NSMenuItem?

    init(defaults: UserDefaults = .standard) {
        preferences = MonitorPreferences(defaults: defaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--widget-status") {
            reportConfigurations(exitAfter: true)
            return
        }
        configureApplicationMenu()
        applyMenuBarPreference()
        showResourceMonitor()
        monitor.onSample = { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
            self.metricsView.update(snapshot)
            self.resourceView?.metricsView.update(snapshot)
            self.updateStatusItem()
        }
        monitor.start()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func createStatusItem() {
        guard statusItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: MenuBarMetric.width(for: preferences.metrics))
        self.statusItem = statusItem
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "系统状态")
        statusItem.button?.image?.size = NSSize(width: 14, height: 14)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = MenuBarMetric.font
        statusItem.button?.toolTip = "系统状态"
        let menu = NSMenu()
        let metricsItem = NSMenuItem()
        metricsItem.view = metricsView
        menu.addItem(metricsItem)
        menu.addItem(.separator())
        menu.addItem(item("资源监视…", action: #selector(showResourceMonitor)))
        let selection = NSMenuItem(title: "显示内容", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        metricItems = MenuBarMetric.allCases.enumerated().map { index, metric in
            let menuItem = item(metric.label, action: #selector(toggleMetric(_:)))
            menuItem.tag = index
            submenu.addItem(menuItem)
            return menuItem
        }
        submenu.addItem(.separator())
        let iconOnly = item("仅图标", action: #selector(clearMetrics))
        iconOnlyItem = iconOnly
        submenu.addItem(iconOnly)
        selection.submenu = submenu
        menu.addItem(selection)
        menu.addItem(item("关闭菜单栏显示", action: #selector(disableMenuBar)))
        menu.addItem(.separator())
        menu.addItem(item("打开活动监视器", action: #selector(openActivityMonitor)))
        menu.addItem(item("刷新小组件", action: #selector(refreshWidgets)))
        menu.addItem(item("查看小组件状态", action: #selector(showStatus)))
        menu.addItem(.separator())
        menu.addItem(item("退出系统状态", action: #selector(quit)))
        statusItem.menu = menu
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }

    private func updateStatusItem() {
        guard let statusItem else { return }
        let selected = preferences.metrics
        let title = MenuBarMetric.title(for: selected, snapshot: snapshot)
        statusItem.length = MenuBarMetric.width(for: selected)
        statusItem.button?.title = title
        statusItem.button?.setAccessibilityLabel(title.isEmpty ? "系统状态" : "系统状态，\(title)")
        for menuItem in metricItems {
            menuItem.state = selected.contains(MenuBarMetric.allCases[menuItem.tag]) ? .on : .off
        }
        iconOnlyItem?.state = selected.isEmpty ? .on : .off
    }

    private func applyMenuBarPreference() {
        if preferences.menuBarEnabled {
            createStatusItem()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            metricItems = []
            iconOnlyItem = nil
        }
        resourceView?.updatePreferences(preferences)
        updateStatusItem()
    }

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        let metric = MenuBarMetric.allCases[sender.tag]
        var selected = preferences.metrics
        if selected.contains(metric) { selected.remove(metric) }
        else { selected.insert(metric) }
        preferences.metrics = selected
        resourceView?.updatePreferences(preferences)
        updateStatusItem()
    }

    @objc private func clearMetrics() {
        preferences.metrics = []
        resourceView?.updatePreferences(preferences)
        updateStatusItem()
    }

    @objc private func disableMenuBar() {
        preferences.menuBarEnabled = false
        applyMenuBarPreference()
        showResourceMonitor()
    }

    @objc private func showResourceMonitor() {
        if window == nil {
            let view = ResourceMonitorContentView()
            view.onMenuBarChanged = { [weak self] enabled in
                guard let self else { return }
                self.preferences.menuBarEnabled = enabled
                self.applyMenuBarPreference()
            }
            view.onMetricsChanged = { [weak self] metrics in
                guard let self else { return }
                self.preferences.metrics = metrics
                self.updateStatusItem()
            }
            view.onActivityMonitor = { [weak self] in self?.openActivityMonitor() }
            view.onRefreshWidgets = { [weak self] in self?.refreshWidgets() }
            view.updatePreferences(preferences)
            if let snapshot { view.metricsView.update(snapshot) }
            resourceView = view
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "资源监视"
            window.level = .normal
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if preferences.menuBarEnabled { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !preferences.menuBarEnabled
    }

    private func configureApplicationMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(item("资源监视…", action: #selector(showResourceMonitor)))
        menu.addItem(.separator())
        let quitItem = item("退出系统状态", action: #selector(quit))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
        application.submenu = menu
        main.addItem(application)
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "desktop-monitor" && $0.host == "refresh" }) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showResourceMonitor()
        return false
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func refreshWidgets() { WidgetCenter.shared.reloadAllTimelines() }
    @objc private func showStatus() { reportConfigurations(exitAfter: false) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func reportConfigurations(exitAfter: Bool) {
        WidgetCenter.shared.getCurrentConfigurations { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let configurations):
                    if exitAfter {
                        let data = try! JSONSerialization.data(withJSONObject: configurations.map { ["kind": $0.kind, "family": String(describing: $0.family)] }, options: [.prettyPrinted, .sortedKeys])
                        print(String(data: data, encoding: .utf8)!)
                        NSApp.terminate(nil)
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "系统状态"
                        alert.informativeText = "已添加 \(configurations.count) 个原生小组件。"
                        alert.runModal()
                    }
                case .failure(let error):
                    if exitAfter {
                        fputs("Widget status: \(error)\n", stderr)
                        exit(1)
                    } else {
                        let alert = NSAlert(error: error)
                        alert.runModal()
                    }
                }
            }
        }
    }
}

#if !HOST_CHECKS
@main
struct NativeHostApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = NativeHostDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
