import XCTest
@testable import FileVaultCore

/// v4.2.31 sweep guards:
/// 1. A root removed from Settings while a sweep is re-attaching it must not
///    come back as a live watcher that keeps committing it.
/// 2. A configured-but-unattached folder whose .git is gone must announce its
///    re-initialisation when the sweep adopts it (same invariant as startup).
final class SweepRaceGuardTests: XCTestCase {

    private func stripFromConfig(_ service: FileVaultService, root: String) {
        var cfg = service.configStore.load()
        cfg.roots.removeAll { $0.path == root }
        _ = service.configStore.save(cfg)
    }

    func testSweepDoesNotResurrectRootRemovedMidAttach() async throws {
        let base = TestSupport.makeTempDir("sweeprace")
        defer { try? FileManager.default.removeItem(atPath: base) }
        // A tiny pre-configured root so start()'s own attach path is exercised
        // and the startup catch-up sweep has real (but fast) work that finishes
        // long before the big root is configured below.
        let small = base + "/small"
        try? FileManager.default.createDirectory(atPath: small, withIntermediateDirectories: true)
        TestSupport.write("seed", to: small + "/seed.md")
        // Enough files that createRepo's status + initial commit take a while:
        // the removal below must land while the attach is still in flight.
        let big = base + "/bigroot"
        try? FileManager.default.createDirectory(atPath: big, withIntermediateDirectories: true)
        for i in 0..<2000 {
            TestSupport.write("x\(i)", to: big + "/file\(i).txt")
        }

        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        var cfg = service.configStore.load()
        cfg.roots = [ManagedRoot(path: small)]
        XCTAssertTrue(service.configStore.save(cfg))
        try await service.start()
        XCTAssertTrue(service.isAttached(root: small))
        // Let the startup catch-up sweep finish its pass over the small root
        // before the big one appears in the config.
        try? await Task.sleep(nanoseconds: 300_000_000)

        // The big root is now configured but has never been attached (like a
        // folder on a disk that was away at startup), so a sweep is the only
        // thing that would attach it.
        cfg = service.configStore.load()
        cfg.roots.append(ManagedRoot(path: big))
        XCTAssertTrue(service.configStore.save(cfg))

        let sweep = Task.detached { await service.sweepOnce() }
        // Removed from Settings while the sweep is busy initialising the repo
        // (.git appears at the very start of the attach; the status + initial
        // commit of 2000 files keep it in flight for a while after).
        let start = Date()
        while Date().timeIntervalSince(start) < 15 {
            if FileManager.default.fileExists(atPath: big + "/.git") { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        stripFromConfig(service, root: big)

        await sweep.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: big + "/.git"),
                      "the sweep did attach the root (this is what the undo must clean up)")
        XCTAssertFalse(service.isAttached(root: big),
                       "a root removed mid-sweep must not keep a live watcher")
        XCTAssertFalse(service.rootsSnapshot().contains(big))
        let after = service.configStore.load()
        XCTAssertFalse(after.roots.contains { $0.path == big })
    }

/// v4.2.31 second-loop guard: the self-heal loop iterates a SNAPSHOT taken
    /// before its awaits; a root removed from Settings while an earlier
    /// iteration was committing must not be committed (and its stopped watcher
    /// must not be restarted) by the time the loop reaches it.
    func testSweepSelfHealSkipsRootRemovedMidLoop() async throws {
        let base = TestSupport.makeTempDir("sweepselfheal")
        defer { try? FileManager.default.removeItem(atPath: base) }

        // Root A: attached with a live watcher; made dirty with many files so
        // the sweep's commit of A stays in flight long enough for the removal
        // below to land before the loop ever reaches X.
        let aRoot = base + "/bigroot"
        try? FileManager.default.createDirectory(atPath: aRoot, withIntermediateDirectories: true)
        for i in 0..<2000 {
            TestSupport.write("x\(i)", to: aRoot + "/file\(i).txt")
        }
        // Root X: attached as well. Its single uncommitted change is the
        // canary — nothing but the stale iteration may commit it (removeRoot
        // cancels the pending debounce commit; the safety sweep is the only
        // other writer, and it must skip a root the user just unprotected).
        let xRoot = base + "/victim"
        try? FileManager.default.createDirectory(atPath: xRoot, withIntermediateDirectories: true)
        TestSupport.write("seed", to: xRoot + "/seed.md")

        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        var cfg = service.configStore.load()
        cfg.roots = [ManagedRoot(path: aRoot), ManagedRoot(path: xRoot)]
        XCTAssertTrue(service.configStore.save(cfg))
        try await service.start()
        XCTAssertTrue(service.isAttached(root: aRoot))
        XCTAssertTrue(service.isAttached(root: xRoot))
        // Let the startup catch-up sweep finish its pass over the clean roots.
        try? await Task.sleep(nanoseconds: 300_000_000)

        for i in 0..<2000 {
            TestSupport.write("y\(i)", to: aRoot + "/dirty\(i).txt")
        }
        TestSupport.write("canary", to: xRoot + "/canary.md")

        let sweep = Task.detached { await service.sweepOnce() }
        // Land the removal while the sweep is still committing A (thousands of
        // new files keep that iteration in flight for seconds).
        try? await Task.sleep(nanoseconds: 200_000_000)
        await service.removeRoot(path: xRoot)
        await sweep.value

        XCTAssertFalse(service.isAttached(root: xRoot), "removeRoot must win")
        XCTAssertFalse(service.configStore.load().roots.contains { $0.path == xRoot })
        let log = try await service.history.commits(repoPath: xRoot, limit: 10)
        XCTAssertEqual(log.count, 1,
                       "the canary change must not be committed for a removed root; subjects: "
                       + log.map(\.subject).joined(separator: " || "))
        XCTAssertFalse(log.contains { $0.subject.contains("canary") },
                       "the stale self-heal iteration committed the removed root's change")
        // The sweep must still have done its real job for the surviving root.
        XCTAssertTrue(service.isAttached(root: aRoot))
        XCTAssertTrue(service.configStore.load().roots.contains { $0.path == aRoot })
    }

    func testSweepAnnouncesReinitialisedRootItAdopts() async throws {
        let base = TestSupport.makeTempDir("sweepreinit")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = base + "/vault"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        TestSupport.write("precious", to: folder + "/precious.md")

        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try? await Task.sleep(nanoseconds: 300_000_000)
        // Configured while unattached: the folder lost its .git while the app
        // was not watching (mirrors testStartupAnnouncesReinitialisedRoot,
        // but adopted by the sweep instead of startup).
        var cfg = service.configStore.load()
        cfg.roots.append(ManagedRoot(path: folder))
        XCTAssertTrue(service.configStore.save(cfg))

        var messages: [String] = []
        let lock = NSLock()
        service.onFailure.handler = { title, body in
            lock.lock(); messages.append(title + "|" + body); lock.unlock()
        }
        await service.sweepOnce()
        lock.lock(); let seen = messages; lock.unlock()
        XCTAssertTrue(seen.contains { $0.contains("重新初始化") },
                      "a sweep-adopted folder that lost its .git must be announced: "
                      + seen.joined(separator: " || "))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/.git"))
        XCTAssertTrue(service.isAttached(root: folder))
    }
}
