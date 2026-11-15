import SwiftUI
import ServiceManagement
import FileVaultCore

/// @main SwiftUI lifecycle (v3.0.0): MenuBarExtra + native window scenes
/// replace the former NSStatusItem/NSMenu/NSWindowController shell.
@main
struct FileVaultApp: App {
    @StateObject private var app = AppState.shared

    init() {
        handleEarlyExitFlags()
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
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
        .menuBarExtraStyle(.menu)

        Window("FileVault", id: "dashboard") {
            DashboardView()
                .environmentObject(app)
                .frame(minWidth: 620, minHeight: 560)
        }

        Window("FileVault 设置", id: "settings") {
            SettingsView()
                .environmentObject(app)
                .frame(minWidth: 660, minHeight: 560)
        }

        Window("FileVault 历史", id: "history") {
            HistoryView()
                .environmentObject(app)
                .frame(minWidth: 660, minHeight: 520)
        }

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
              --open-ui a,b,c     Open windows (settings,dashboard,history) in the running app
              --render-* <path>   Render a window to PNG and exit
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
        let map = ["--render-settings": ("settings", "FileVault 设置"),
                   "--render-history": ("history", "FileVault 历史"),
                   "--render-dashboard": ("dashboard", "FileVault")]
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
