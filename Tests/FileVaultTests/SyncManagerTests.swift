import XCTest
@testable import FileVaultCore

final class SyncManagerTests: XCTestCase {
    var root: String!
    var repos: RepoManager!
    var sync: SyncManager!

    override func setUp() {
        root = TestSupport.makeTempDir("synroot")
        try? FileManager.default.createDirectory(atPath: root + "/repoA", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/repoA/seed.txt")
        repos = RepoManager(runner: TestSupport.newRunner())
        sync = SyncManager(repoManager: repos, backoffSchedule: [0.1], maxAttempts: 2)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    private func makeBareRemote(_ name: String) -> String {
        let remote = root + "/\(name).git"
        _ = try? repos.runner.runSync(["init", "--bare", remote], cwd: root, timeout: 10)
        return remote
    }

    private func waitForStatus(_ expected: SyncStatus, repo: String, timeout: Double = 10) async {
        var waited = 0.0
        while waited < timeout {
            let st = await sync.status(for: repo)
            if st == expected { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        let final = await sync.status(for: repo)
        XCTAssertEqual(final, expected)
    }

    func testAutoPushAfterCommit() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: root + "/repoA")
        let remote = makeBareRemote("r1")
        try await sync.configureRemote(repoPath: repo, url: remote, autoPush: true)
        TestSupport.write("data", to: repo + "/f.md")
        _ = try await repos.commitAll(path: repo)
        await sync.enqueuePush(repoPath: repo)
        await waitForStatus(.synced, repo: repo)
        let r = try await repos.runner.run(["--git-dir=\(remote)", "log", "--oneline"], cwd: remote)
        XCTAssertTrue(r.succeeded)
        XCTAssertTrue(r.stdout.contains("auto:"))
    }

    func testNoRemoteStatus() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: root + "/repoA")
        let st = await sync.status(for: repo)
        XCTAssertEqual(st, .noRemote)
        await sync.enqueuePush(repoPath: repo)
        let st2 = await sync.status(for: repo)
        XCTAssertEqual(st2, .noRemote)
    }

    func testPushFailureThenManualRetry() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: root + "/repoA")
        // Remote path does not exist yet -> push fails.
        let remote = root + "/not-yet.git"
        try await sync.configureRemote(repoPath: repo, url: remote, autoPush: true)
        await waitForStatus(.failed, repo: repo)
        // Create the remote, then manual retry succeeds.
        _ = makeBareRemote("not-yet")
        let ok = await sync.pushNow(repoPath: repo)
        XCTAssertTrue(ok)
        await waitForStatus(.synced, repo: repo)
    }

    func testAutoPushDisabledStaysPending() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: root + "/repoA")
        let remote = makeBareRemote("r2")
        try await sync.configureRemote(repoPath: repo, url: remote, autoPush: false)
        // Local commits exist but never pushed -> pendingPush is correct semantics.
        await waitForStatus(.pendingPush, repo: repo)
        let ok0 = await sync.pushNow(repoPath: repo)
        XCTAssertTrue(ok0)
        await waitForStatus(.synced, repo: repo)
        TestSupport.write("more", to: repo + "/f2.md")
        _ = try await repos.commitAll(path: repo)
        await sync.enqueuePush(repoPath: repo)
        await waitForStatus(.pendingPush, repo: repo)
        let ok = await sync.pushNow(repoPath: repo)
        XCTAssertTrue(ok)
    }
}
