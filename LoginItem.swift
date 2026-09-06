import AppKit
import ServiceManagement

final class LoginItemController {
    private let service = SMAppService.mainApp

    var status: SMAppService.Status { service.status }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if status != .enabled && status != .requiresApproval { try service.register() }
        } else if status == .enabled || status == .requiresApproval {
            try service.unregister()
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum LoginLaunch {
    static func isLoginItem(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    static func shouldShowWindow(isLoginItem: Bool, menuBarEnabled: Bool) -> Bool {
        !isLoginItem || !menuBarEnabled
    }
}
