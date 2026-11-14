import XCTest
@testable import FileVaultCore

final class ConfigStoreTests: XCTestCase {
    func testRoundtrip() {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("cfg"))
        let store = ConfigStore(directory: dir)
        var cfg = store.load()
        XCTAssertEqual(cfg.roots.count, 0)
        cfg.roots.append(ManagedRoot(path: "/tmp/demo-vault"))
        cfg.roots.append(ManagedRoot(path: "/tmp/second", paused: true))
        store.save(cfg)
        let store2 = ConfigStore(directory: dir)
        let loaded = store2.load()
        XCTAssertEqual(loaded.roots.count, 2)
        XCTAssertEqual(loaded.roots[0].path, "/tmp/demo-vault")
        XCTAssertTrue(loaded.roots[1].paused)
    }

    func testManagedRootResolvesSymlinks() {
        let real = TestSupport.makeTempDir("root-real")
        let link = TestSupport.makeTempDir("root-link")
        _ = try? FileManager.default.removeItem(atPath: link)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let mr = ManagedRoot(path: link)
        XCTAssertEqual(mr.path, real)
    }
}
