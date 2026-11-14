import Foundation
import AppKit
import FileVaultCore

// Argument handling
let args = CommandLine.arguments
if args.contains("--help") {
    print("""
    FileVault — Git-backed file history keeper in the macOS menu bar.

    USAGE: FileVaultApp [option]

    OPTIONS:
      (no args)   Launch the menu bar app (default)
      --smoke     Run core self-check (git detect / add-root / auto-commit / push) and exit
      --help      Show this help
    """)
    exit(0)
}

if args.contains("--smoke") {
    let ok = SmokeTest.run()
    exit(ok ? 0 : 1)
}

// Menu bar app (accessory: no Dock icon, resident in the menu bar).
let app = NSApplication.shared
let delegate = AppDelegate(service: nil)
app.delegate = delegate
app.setActivationPolicy(.accessory)
delegate.buildStatusItem()
app.run()
