import SwiftUI
import ServiceManagement
import FileVaultCore

/// @main SwiftUI lifecycle (v3.0.0): MenuBarExtra + native window scenes
/// replace the former NSStatusItem/NSMenu/NSWindowController shell.
@main
struct FileVaultApp: App {
    @StateObject private var app = AppState.shared

    init() {
        // v3.4.0: honour the app-language choice before any UI is built.
        let stored = ConfigStore().load().general.language
        AppLanguage.apply(AppLanguage.storedValue(stored))
        handleEarlyExitFlags()
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        // Diagnostic hook: screenshot tooling renders a forced appearance without
        // touching the user's system setting (FV_FORCE_APPEARANCE=dark|light).
        switch ProcessInfo.processInfo.environment["FV_FORCE_APPEARANCE"] {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: break
        }
        Task { @MainActor in
            AppState.shared.start()
            await AppState.shared.runDiagnosticsIfRequested()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(app)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: app.menuIcon)
                OpenerHook()
            }
        }
        .menuBarExtraStyle(.window)

        Window("FileVault", id: "dashboard") {
            DashboardView()
                .environmentObject(app)
        }
        // Content-sized: the dashboard is laid out to fit and never scrolls.
        .windowResizability(.contentSize)
        .defaultSize(width: 820, height: 640)

        Window("FileVault 设置", id: "settings") {
            SettingsView()
                .environmentObject(app)
        }
        .defaultSize(width: 780, height: 760)

        Window("FileVault 历史", id: "history") {
            HistoryView()
                .environmentObject(app)
        }
        .defaultSize(width: 1000, height: 640)

        // v4.1: file-first recovery. 恢复 = 找回删除的文件 / 还原改过的文件.
        Window("FileVault 恢复", id: "recovery") {
            RecoveryView()
                .environmentObject(app)
        }
        .defaultSize(width: 1060, height: 680)

        #if DEBUG
        // Dev-only: lets --render-menu capture the panel as a PNG.
        Window("FileVault 菜单", id: "menu-preview") {
            MenuPreviewView()
                .environmentObject(app)
        }
        .defaultSize(width: 420, height: 700)
        #endif
    }

    /// Flags that must act before any UI exists.
    private func handleEarlyExitFlags() {
        let args = CommandLine.arguments
        if args.contains("--help") {
            print("""
            FileVault — Git-backed file history keeper in the macOS menu bar.

            USAGE: FileVaultApp [option]

            OPTIONS:
              (no args)           Launch the menu bar app (default)
              --smoke             Run core self-check (git detect / add-root / auto-commit / push) and exit
              --launch-status     Inspect the login-item registration state
              --launch-register   Register the app as a login item
              --launch-unregister Unregister the login item
              --open-ui a,b,c     Open windows (settings,dashboard,history,recovery) in the running app
              --render-* <path>   Render a window to PNG and exit (debug: menu too)
              --help              Show this help
            """)
            exit(0)
        }
        if args.contains("--smoke") {
            let ok = SmokeTest.run()
            exit(ok ? 0 : 1)
        }
        if args.contains("--launch-status") || args.contains("--launch-register") || args.contains("--launch-unregister") {
            let svc = SMAppService.mainApp
            print("status(before): \(svc.status)")
            if args.contains("--launch-register") {
                do { try svc.register(); print("register: ok") } catch { print("register ERROR: \(error)") }
            }
            if args.contains("--launch-unregister") {
                do { try svc.unregister(); print("unregister: ok") } catch { print("unregister ERROR: \(error)") }
            }
            print("status(after): \(svc.status)")
            exit(0)
        }
        // Render diagnostics: map --render-settings/--render-history/
        // --render-dashboard to an open+capture request.
        // Titles are localised, so resolve them through the same table the
        // window scenes use (v3.4.0).
        var map = ["--render-settings": ("settings", NSLocalizedString("FileVault 设置", comment: "window title")),
                   "--render-history": ("history", NSLocalizedString("FileVault 历史", comment: "window title")),
                   "--render-recovery": ("recovery", NSLocalizedString("FileVault 恢复", comment: "window title")),
                   "--render-dashboard": ("dashboard", "FileVault")]
        #if DEBUG
        map["--render-menu"] = ("menu-preview", "FileVault 菜单")
        #endif
        for (flag, pair) in map {
            if let idx = args.firstIndex(of: flag), args.indices.contains(idx + 1) {
                AppState.shared.renderRequest = AppState.RenderRequest(
                    sceneID: pair.0, windowTitle: pair.1, outPath: args[idx + 1])
            }
        }
        if let idx = args.firstIndex(of: "--open-ui"), args.indices.contains(idx + 1) {
            AppState.shared.pendingOpenUI = args[idx + 1].split(separator: ",").map(String.init)
        }
    }
}

/// Invisible view inside the MenuBarExtra label: captures the SwiftUI
/// `openWindow` environment action so AppState can open scenes
/// programmatically (onboarding, diagnostics, --open-ui).
struct OpenerHook: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { AppState.shared.openWindowHandler = { id in openWindow(id: id) } }
    }
}
