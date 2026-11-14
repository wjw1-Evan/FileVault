import AppKit
import UserNotifications
import FileVaultCore

/// System notifications for commit/push failures (FR-18).
/// Best-effort: degrades silently when the runtime cannot post notifications
/// (e.g. unbundled debug binaries), so core flows are never affected.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var authorized = false
    /// User preference (general settings) — persisted in config.json.
    var enabled = true

    func setup() {
        // UNUserNotificationCenter.current() throws an uncatchable ObjC
        // exception in unbundled executables ("bundleProxyForCurrentProcess
        // is nil") — degrade gracefully when running without an app bundle.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.authorized = granted
            }
        }
    }

    func notifyFailure(_ title: String, _ body: String) {
        guard authorized, enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Show banners even when the accessory app is not frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
