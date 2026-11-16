import AppKit
import UserNotifications
import FileVaultCore

/// System notifications for commit/push failures (FR-18).
/// Best-effort: degrades silently when the runtime cannot post notifications
/// (e.g. unbundled debug binaries), so core flows are never affected.
///
/// v4.2.26: notifications raised BEFORE the authorization callback returned were
/// dropped (startup config recovery, ".git re-initialised", rollback notice).
/// They are queued now and flushed once authorization resolves.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let lock = NSLock()
    private var authorized = false
    private var pending: [(title: String, body: String)] = []
    private var enabledStorage = true

    /// User preference (general settings) — persisted in config.json.
    var enabled: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return enabledStorage
        }
        set {
            lock.lock()
            enabledStorage = newValue
            if !newValue { pending.removeAll() }
            lock.unlock()
        }
    }

    func setup() {
        // UNUserNotificationCenter.current() throws an uncatchable ObjC
        // exception in unbundled executables ("bundleProxyForCurrentProcess
        // is nil") — degrade gracefully when running without an app bundle.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.setAuthorized(granted)
            }
        }
    }

    private func setAuthorized(_ granted: Bool) {
        lock.lock()
        authorized = granted
        let queued = granted ? pending : []
        pending.removeAll()
        lock.unlock()
        guard granted else { return }
        for item in queued { deliver(title: item.title, body: item.body) }
    }

    func notifyFailure(_ title: String, _ body: String) {
        lock.lock()
        let sendNow = authorized && enabledStorage
        if !sendNow, enabledStorage, pending.count < 20 {
            pending.append((title, body))
        }
        lock.unlock()
        guard sendNow else { return }
        deliver(title: title, body: body)
    }

    private func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Show banners even when the accessory app is not frontmost.
    ///
    /// Must be the *async* protocol requirement: without `async` the method
    /// only "nearly matches" UNUserNotificationCenterDelegate and is never
    /// called (the compiler warns about it), so foreground banners were lost
    /// (v4.2.26).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Tapping a failure banner used to just activate the accessory app with no
    /// window — the user stared at nothing. Failure-class banners open the
    /// dashboard where the activity feed shows the reason (v4.2.27).
    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        AppState.shared.open("dashboard")
    }
}
