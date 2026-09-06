import AppKit
import WidgetKit

final class NativeHostDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--widget-status") {
            reportConfigurations(exitAfter: true)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "系统状态")
        statusItem.button?.toolTip = "系统状态小组件"
        let menu = NSMenu()
        menu.addItem(item("刷新小组件", action: #selector(refreshWidgets)))
        menu.addItem(item("查看小组件状态", action: #selector(showStatus)))
        menu.addItem(.separator())
        menu.addItem(item("退出菜单栏应用", action: #selector(quit)))
        statusItem.menu = menu
        WidgetCenter.shared.reloadAllTimelines()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "desktop-monitor" && $0.host == "refresh" }) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WidgetCenter.shared.reloadAllTimelines()
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
