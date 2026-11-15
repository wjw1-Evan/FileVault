import XCTest
@testable import FileVaultApp

/// Settings fold state for root cards (v3.4.2).
final class RootCollapseStateTests: XCTestCase {
    func testStartsExpanded() {
        let state = RootCollapseState()
        XCTAssertTrue(state.isEmpty)
        XCTAssertFalse(state.isCollapsed("/tmp/a"))
    }

    func testToggleFoldsAndUnfolds() {
        var state = RootCollapseState()
        state.toggle("/tmp/a")
        XCTAssertTrue(state.isCollapsed("/tmp/a"))
        XCTAssertFalse(state.isCollapsed("/tmp/b"))
        state.toggle("/tmp/a")
        XCTAssertFalse(state.isCollapsed("/tmp/a"))
    }

    func testCollapseAllAndExpandAll() {
        var state = RootCollapseState()
        state.collapseAll(["/a", "/b", "/c"])
        XCTAssertTrue(state.isCollapsed("/a"))
        XCTAssertTrue(state.isCollapsed("/c"))
        state.expandAll()
        XCTAssertTrue(state.isEmpty)
    }

    func testPersistsToUserDefaults() {
        let name = "fv.collapse.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var state = RootCollapseState()
        state.toggle("/tmp/a")
        state.toggle("/tmp/b")
        state.save(to: defaults)

        let reloaded = RootCollapseState.load(from: defaults)
        XCTAssertTrue(reloaded.isCollapsed("/tmp/a"))
        XCTAssertTrue(reloaded.isCollapsed("/tmp/b"))
        XCTAssertEqual(reloaded, state)
    }

    func testLoadHandlesMissingKey() {
        let name = "fv.collapse.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(RootCollapseState.load(from: defaults).isEmpty)
    }
}
