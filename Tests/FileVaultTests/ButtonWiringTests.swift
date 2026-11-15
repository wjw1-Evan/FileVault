import XCTest
import AppKit
@testable import FileVaultCore
@testable import FileVaultApp

/// v2.6.7 button-wiring audit: EVERY interactive control in every window and
/// the menu bar must have a target whose class actually implements the action.
/// This is the systemic guard for the whole "button dead" bug class (weak
/// controller orphan windows, missing target assignment — e.g. filesLabel).
final class ButtonWiringTests: XCTestCase {
    @MainActor
    private func makeService(_ tag: String) async throws -> (FileVaultService, String) {
        let base = TestSupport.makeTempDir("btnwiring-\(tag)")
        try? FileManager.default.createDirectory(atPath: base + "/vault/alpha", withIntermediateDirectories: true)
        TestSupport.write("s", to: base + "/vault/alpha/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        return (service, base)
    }

    /// Generic invariant: any control WE wired must have a live target that
    /// implements its action. Controls without an action (plain fields) are skipped.
    private func assertAllWired(_ v: NSView, _ context: String) {
        if let b = v as? NSButton {
            // By-design form control: 自动推送 is persisted together with the
            // remote URL by the 保存 button (the row is a save-driven form),
            // so the checkbox itself carries no action — covered by the save flow.
            let formControl = b.title == "自动推送"
            if !formControl {
                XCTAssertNotNil(b.action, "\(context): button '\(b.title)' has no action")
                XCTAssertNotNil(b.target, "\(context): button '\(b.title)' has no target")
                if let t = b.target, let a = b.action {
                    XCTAssertTrue(t.responds(to: a), "\(context): target \(type(of: t)) does not implement \(a) for '\(b.title)'")
                }
            }
        }
        if let p = v as? NSPopUpButton {
            if p.action != nil {
                XCTAssertNotNil(p.target, "\(context): popup has action but no target")
                if let t = p.target, let a = p.action {
                    XCTAssertTrue(t.responds(to: a), "\(context): popup target does not implement \(a)")
                }
            }
        }
        for sub in v.subviews { assertAllWired(sub, context) }
    }

    @MainActor
    func testSettingsWindowAllButtonsWired() async throws {
        let (service, base) = try await makeService("settings")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let controller = SettingsWindowController(service: service)
        defer { controller.window?.close() }
        assertAllWired(controller.window?.contentView ?? NSView(), "settings")

        // Inventory: every management control must exist AND be wired.
        var buttons: [String: NSButton] = [:]
        var popups: [NSPopUpButton] = []
        func collect(_ v: NSView) {
            if let b = v as? NSButton, !b.title.isEmpty { buttons[b.title] = b }
            if let p = v as? NSPopUpButton { popups.append(p) }
            for sub in v.subviews { collect(sub) }
        }
        collect(controller.window?.contentView ?? NSView())
        let expected = ["＋ 添加根目录…", "打开配置文件", "打开", "移除", "保存",
                        "立即推送", "测试连接", "忽略规则", "拉取", "建仓"]
        for title in expected {
            guard let b = buttons[title] else {
                return XCTFail("settings missing button '\(title)'")
            }
            XCTAssertNotNil(b.target, "'\(title)' unwired target")
            XCTAssertNotNil(b.action, "'\(title)' unwired action")
        }
        XCTAssertGreaterThanOrEqual(popups.count, 2, "debounce + auth popups must exist")
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func testHistoryWindowAllButtonsWired() async throws {
        let (service, base) = try await makeService("history")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let controller = HistoryWindowController(service: service)
        controller.showWindow(nil)
        defer { controller.window?.close() }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        assertAllWired(controller.window?.contentView ?? NSView(), "history")

        // Inline per-row 恢复 buttons exist once a commit is auto-selected.
        var restoreButtons = 0
        func walk(_ v: NSView) {
            if let b = v as? NSButton, b.title == "恢复" { restoreButtons += 1 }
            for sub in v.subviews { walk(sub) }
        }
        walk(controller.window?.contentView ?? NSView())
        XCTAssertGreaterThan(restoreButtons, 0, "inline restore buttons must exist for the selected commit")
        // Rollback button present and wired.
        let rollback = deepButton(controller.window?.contentView, title: "回滚整个文件夹到此版本")
        XCTAssertNotNil(rollback)
        XCTAssertNotNil(rollback?.target)
        XCTAssertNotNil(rollback?.action)
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func testDashboardWindowAllButtonsWired() async throws {
        let (service, base) = try await makeService("dashboard")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let controller = DashboardWindowController(service: service)
        controller.showWindow(nil)   // 打开 rows appear via the async refresh()
        defer { controller.window?.close() }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        assertAllWired(controller.window?.contentView ?? NSView(), "dashboard")
        for title in ["设置", "历史", "打开"] {
            let b = deepButton(controller.window?.contentView, title: title)
            XCTAssertNotNil(b, "dashboard missing '\(title)'")
            XCTAssertNotNil(b?.target, "'\(title)' unwired")
        }
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func testGitignoreEditorSaveWired() async throws {
        let (service, base) = try await makeService("gitignore")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = base + "/vault/alpha"
        let editor = GitignoreEditorController(repoPath: folder, repos: service.repoManager)
        defer { editor.window?.close() }
        assertAllWired(editor.window?.contentView ?? NSView(), "gitignore editor")
        let save = deepButton(editor.window?.contentView, title: "保存（改动会被自动提交）")
        XCTAssertNotNil(save, "save button missing")
        XCTAssertTrue(save?.target?.responds(to: save?.action ?? nil as Selector?) ?? false, "save unwired")
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func testMenuBarMenuItemsWired() async throws {
        let (service, base) = try await makeService("menu")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let delegate = AppDelegate(service: service)
        let items = AppDelegate.buildMenuItems(service: service, statuses: [:], healthCache: [:], target: delegate)
        var checked = 0
        func check(_ item: NSMenuItem) {
            if let action = item.action, action != NSSelectorFromString("submenuAction:") {
                XCTAssertNotNil(item.target, "menu item '\(item.title)' has action but no target")
                if let t = item.target {
                    XCTAssertTrue(t.responds(to: action), "menu target does not implement \(action) for '\(item.title)'")
                }
                checked += 1
            }
            if let sub = item.submenu { for s in sub.items { check(s) } }  // must run even for submenu parents
        }
        for i in items { check(i) }
        XCTAssertGreaterThanOrEqual(checked, 8, "menu must wire its actionable items (pause/commit/dashboard/history/settings/about/quit/opens)")
        // Key entries present by title.
        let titles = items.map(\.title)
        for t in ["暂停自动提交", "立即提交全部", "打开主面板", "历史版本…", "设置…", "关于 FileVault", "退出 FileVault"] {
            XCTAssertTrue(titles.contains(t), "menu missing '\(t)'")
        }
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    private func deepButton(_ v: NSView?, title: String) -> NSButton? {
        guard let v else { return nil }
        if let b = v as? NSButton, b.title == title { return b }
        for sub in v.subviews {
            if let b = deepButton(sub, title: title) { return b }
        }
        return nil
    }
}
