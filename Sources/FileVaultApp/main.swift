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

// Diagnostic: render the dashboard to a PNG.
if let idx = args.firstIndex(of: "--render-dashboard"), args.indices.contains(idx + 1) {
    let outPath = args[idx + 1]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task {
        let service = FileVaultService()
        try? await service.start()
        let controller = DashboardWindowController(service: service)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        if let win = controller.window {
            let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.bestResolution])
            if let img {
                let rep = NSBitmapImageRep(cgImage: img)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: outPath))
                    print("rendered: " + outPath)
                }
            }
        }
        exit(0)
    }
    app.run()
    exit(0)
}

// Diagnostic: render the update progress window to a PNG.
if let idx = args.firstIndex(of: "--render-update-progress"), args.indices.contains(idx + 1) {
    let outPath = args[idx + 1]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        let controller = UpdateProgressWindowController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.setStage("下载更新…", fraction: 0.42, detail: "277 KB / 660 KB")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        if let win = controller.window {
            let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.bestResolution])
            if let img {
                let rep = NSBitmapImageRep(cgImage: img)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: outPath))
                    print("rendered: \(outPath)")
                }
            }
        }
        exit(0)
    }
    app.run()
    exit(0)
}

// Diagnostic: render the real settings window to a PNG (visual design review).
if let idx = args.firstIndex(of: "--render-settings"), args.indices.contains(idx + 1) {
    let outPath = args[idx + 1]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task {
        let service = FileVaultService()
        try? await service.start()
        let controller = SettingsWindowController(service: service)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        if let win = controller.window {
            print("win.frame=\(win.frame)")
            if let svc = controller.service {
                print("roots=\(svc.rootsSnapshot().count)")
            }
            if let stack = controller.contentStack {
                print("contentStack.frame=\(stack.frame) arranged=\(stack.arrangedSubviews.count)")
                for (i, v) in stack.arrangedSubviews.enumerated().prefix(4) {
                    print("  card[\(i)]: \(type(of: v)) frame=\(v.frame)")
                }
            }
            if let cv = win.contentView as? NSView {
                print("host.frame=\(cv.frame)")
                for sub in cv.subviews {
                    print("sub: \(type(of: sub)) frame=\(sub.frame)")
                    for ss in sub.subviews {
                        print("  sub2: \(type(of: ss)) frame=\(ss.frame)")
                        for s3 in ss.subviews.prefix(3) {
                            print("    sub3: \(type(of: s3)) frame=\(s3.frame)")
                        }
                    }
                }
            }
            let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.bestResolution])
            if let img {
                let rep = NSBitmapImageRep(cgImage: img)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: outPath))
                    print("rendered: \(outPath)")
                }
            }
        }
        exit(0)
    }
    app.run()
    exit(0)
}

// Menu bar app (accessory: no Dock icon, resident in the menu bar).
let app = NSApplication.shared
let delegate = AppDelegate(service: nil)
app.delegate = delegate
app.setActivationPolicy(.accessory)
delegate.buildStatusItem()
app.run()
