import AppKit
import WidgetKit

final class NativeHostDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private(set) var statusItem: NSStatusItem?
    private(set) var window: NSWindow?
    private(set) var resourceView: ResourceMonitorContentView?
    private(set) var dashboard: ResourceDashboardView?
    let statusMenuView = StatusMenuController()
    private let preferences: MonitorPreferences
    private let monitor = LiveMetricsMonitor()
    private let detailMonitor = DetailedMonitor()
    private let loginItem = LoginItemController()
    private var launchedAtLogin = false
    private var snapshot: MetricsSnapshot?
    private var statusMenuIsOpen = false
    private var resourceWindowNeedsSampling = false

    init(defaults: UserDefaults = .standard) {
        preferences = MonitorPreferences(defaults: defaults)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = LoginLaunch.isLoginItem(NSAppleEventManager.shared().currentAppleEvent)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--login-item-status") {
            print("Login item status: \(loginItem.status.rawValue)")
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--widget-status") {
            reportConfigurations()
            return
        }
        configureApplicationMenu()
        detailMonitor.onSample = { [weak self] details in
            guard let self else { return }
            self.statusMenuView.updateDetails(details)
            if self.resourceWindowNeedsSampling { self.dashboard?.updateDetails(details) }
        }
        applyMenuBarPreference()
        launchedAtLogin = launchedAtLogin || LoginLaunch.isLoginItem(NSAppleEventManager.shared().currentAppleEvent)
        if LoginLaunch.shouldShowWindow(isLoginItem: launchedAtLogin, menuBarEnabled: preferences.menuBarEnabled) {
            showResourceMonitor()
        }
        monitor.onSample = { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
            self.statusMenuView.update(snapshot)
            self.resourceView?.metricsView.update(snapshot)
            self.dashboard?.update(snapshot)
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
        let menu = statusMenuView.menu
        menu.delegate = self
        statusItem.menu = menu
        statusMenuView.onSelection = { [weak self] selected in
            guard let self else { return }
            self.preferences.metrics = selected
            self.resourceView?.updatePreferences(self.preferences)
            self.updateStatusItem()
        }
        statusMenuView.onOpenMonitor = { [weak self] page in
            self?.showResourceMonitor()
            self?.dashboard?.tabs.selectTabViewItem(at: page)
        }
        statusMenuView.onChooseFolder = { [weak self] in self?.chooseMenuDiskFolder() }
        statusMenuView.onDisable = { [weak self] in self?.disableMenuBar() }
        statusMenuView.onQuit = { [weak self] in self?.quit() }
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) { monitor.stop(); detailMonitor.stop(); dashboard?.disk.cancel(); statusMenuView.disk.cancel() }

    func applicationDidBecomeActive(_ notification: Notification) {
        resourceView?.updateLoginItem(loginItem.status)
    }

    private func updateStatusItem() {
        guard let statusItem else { return }
        let selected = preferences.metrics
        statusMenuView.updateSelection(selected)
        // Keep the status item's anchor stable until the user closes its menu.
        guard !statusMenuIsOpen else { return }
        let title = MenuBarMetric.title(for: selected, snapshot: snapshot)
        statusItem.length = MenuBarMetric.width(for: selected)
        statusItem.button?.title = title
        statusItem.button?.setAccessibilityLabel(title.isEmpty ? "系统状态" : "系统状态，\(title)")
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusMenuIsOpen = true
        if !resourceWindowNeedsSampling { statusMenuView.updateDetails(nil) }
        updateDetailedSampling()
    }
    func menuDidClose(_ menu: NSMenu) {
        statusMenuIsOpen = false
        statusMenuView.endTracking()
        statusMenuView.disk.cancelPendingAutomaticScan()
        updateStatusItem()
        updateDetailedSampling()
    }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) { statusMenuView.highlight(item) }

    private func updateDetailedSampling() {
        if statusMenuIsOpen || resourceWindowNeedsSampling { detailMonitor.start() }
        else { detailMonitor.stop() }
    }

    private func chooseMenuDiskFolder() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.directoryURL = self.statusMenuView.disk.root; panel.prompt = "扫描"
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { [weak self] response in
                if response == .OK, let url = panel.url { self?.statusMenuView.disk.scanUserSelected(url) }
            }
        }
    }

    private func applyMenuBarPreference() {
        if preferences.menuBarEnabled {
            createStatusItem()
        } else if let statusItem {
            statusItem.menu?.cancelTracking()
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        resourceView?.updatePreferences(preferences)
        updateStatusItem()
    }

    @objc private func disableMenuBar() {
        preferences.menuBarEnabled = false
        applyMenuBarPreference()
        showResourceMonitor()
    }

    @objc private func showResourceMonitor() {
        statusItem?.menu?.cancelTracking()
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
            view.onLoginItemToggle = { [weak self] in self?.toggleLoginItem() }
            view.onLoginItemSettings = { [weak self] in self?.loginItem.openSettings() }
            view.onActivityMonitor = { [weak self] in self?.openActivityMonitor() }
            view.updatePreferences(preferences)
            if let snapshot { view.metricsView.update(snapshot) }
            resourceView = view
            let dashboard = ResourceDashboardView(configuration: view)
            self.dashboard = dashboard
            if let snapshot { dashboard.update(snapshot) }
            let window = NSWindow(contentRect: dashboard.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "资源监视"
            window.level = .normal
            window.isReleasedWhenClosed = false
            window.contentView = dashboard
            window.contentMinSize = NSSize(width: 780, height: 480)
            window.delegate = self
            window.center()
            self.window = window
        }
        resourceView?.updateLoginItem(loginItem.status)
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        resourceWindowNeedsSampling = true
        dashboard?.prepareVisiblePage()
        updateDetailedSampling()
    }

    private func toggleLoginItem() {
        let status = loginItem.status
        do {
            try loginItem.setEnabled(status != .enabled && status != .requiresApproval)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法更改登录启动设置"
            alert.informativeText = "请确认应用位于“应用程序”文件夹，也可在系统登录项设置中查看状态。\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "好")
            if let window { alert.beginSheetModal(for: window) }
        }
        resourceView?.updateLoginItem(loginItem.status)
    }

    func windowWillClose(_ notification: Notification) {
        resourceWindowNeedsSampling = false
        updateDetailedSampling()
        dashboard?.disk.cancelPendingAutomaticScan()
        if preferences.menuBarEnabled { NSApp.setActivationPolicy(.accessory) }
    }

    func windowDidMiniaturize(_ notification: Notification) { resourceWindowNeedsSampling = false; updateDetailedSampling() }
    func windowDidDeminiaturize(_ notification: Notification) { resourceWindowNeedsSampling = true; dashboard?.prepareVisiblePage(); updateDetailedSampling() }

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

    @objc private func quit() { NSApp.terminate(nil) }

    private func reportConfigurations() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let configurations):
                    let data = try! JSONSerialization.data(withJSONObject: configurations.map { ["kind": $0.kind, "family": String(describing: $0.family)] }, options: [.prettyPrinted, .sortedKeys])
                    print(String(data: data, encoding: .utf8)!)
                    NSApp.terminate(nil)
                case .failure(let error):
                    fputs("Widget status: \(error)\n", stderr)
                    exit(1)
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
