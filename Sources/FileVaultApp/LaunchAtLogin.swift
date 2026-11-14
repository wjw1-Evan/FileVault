import Foundation
import ServiceManagement

/// Login-item control via SMAppService (macOS 13+).
/// Only meaningful inside a proper .app bundle; degrades gracefully otherwise.
enum LaunchAtLogin {
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static var isEnabled: Bool {
        guard available else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ on: Bool) throws {
        guard available else { return }
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
