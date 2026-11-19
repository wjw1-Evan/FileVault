import XCTest
@testable import FileVaultCore

/// v4.2.31: a manual push supersedes a running push loop, but the cancelled
/// loop's `finishPushLoop` used to still own the generation slot. When a
/// commit arrived during the manual push, it consumed `needsPushAgain` and
/// restarted a SECOND loop 300 ms later — a `git push` racing the manual one,
/// silently bypassing the `manualPushes` guard.
final class SyncPushGenerationTests: XCTestCase {
    /// Minimal thread-safe completion flag (the toolchain's Task has no
    /// `isCompleted`).
    private final class CompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    func testManualPushSupersedesLoopWithoutRestartingItMidFlight() async throws {
        let base = TestSupport.makeTempDir("syncgen")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/repo",
                                                  withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/repo/seed.txt")

        // Slow-git wrapper: the loop's own push sleeps 1 s (so it is provably
        // inside git when the manual push cancels it); every later push sleeps
        // 3 s (so the manual push is still in flight while a buggy restart
        // would have started its own push).
        let countFile = base + "/push-count"
        let wrapper = base + "/slow-git"
        let script = """
        #!/bin/sh
        for a in "$@"; do
          if [ "$a" = "push" ]; then
            n=$(( $(cat '\(countFile)' 2>/dev/null || echo 0) + 1 ))
            echo "$n" > '\(countFile)'
            if [ "$n" -eq 1 ]; then sleep 1; else sleep 3; fi
            break
          fi
        done
        exec /usr/bin/git "$@"
        """
        TestSupport.write(script, to: wrapper)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)

        let repos = RepoManager(runner: GitRunner(gitExecutable: wrapper, defaultTimeout: 30))
        let sync = SyncManager(repoManager: repos, backoffSchedule: [0.1], maxAttempts: 1)
        let repo = base + "/repo"
        _ = try await repos.ensureRepo(at: repo)
        // A remote path that does not exist: every push fails, but only after
        // the wrapper's sleep.
        try await sync.configureRemote(repoPath: repo, url: base + "/absent.git", autoPush: true)

        // Wait until the auto push loop is provably INSIDE its `git push`
        // (the wrapper bumps the counter before sleeping).
        let start = Date()
        while Date().timeIntervalSince(start) < 10 {
            let n = (try? String(contentsOfFile: countFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if n == "1" { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let counterValue = (try? String(contentsOfFile: countFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(counterValue, "1",
            "the auto push loop must have started its own push before the manual one")
        let statusBeforeManual = await sync.status(for: repo)
        XCTAssertEqual(statusBeforeManual, .pushing)

        // Manual push while the loop's push is still in flight, plus a commit
        // arriving meanwhile (queued through needsPushAgain).
        let finished = CompletionFlag()
        let manual = Task.detached {
            let ok = await sync.pushNow(repoPath: repo)
            finished.set()
            return ok
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        await sync.enqueuePush(repoPath: repo)

        // The loop's slow push returns (~1 s); on the buggy path its
        // finishPushLoop restarted a new loop 300 ms later, while the manual
        // push (3 s sleep) is still running. Sample inside that window.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertFalse(finished.isSet,
                      "the manual push must still be in flight while sampling")
        let restartedLoop = await sync.hasActivePushLoop(repoPath: repo)
        XCTAssertFalse(restartedLoop,
            "a superseded push loop must not restart while the manual push owns the repo")

        let ok = await manual.value
        XCTAssertFalse(ok, "the remote does not exist, so the manual push itself fails")
        // Drop the queued follow-up so the test leaves no loop behind.
        await sync.reset(repoPath: repo)
    }
/// v4.2.31 second door: the rebind's generation claim only guards the
    /// finishPushLoop RESTART path. A commit landing mid-rebind reached
    /// enqueuePush, found no running task and STARTED a loop that pushed to
    /// the OLD remote while setRemote was still swapping it.
    func testRebindHoldsPushSlotAgainstCommitsLandingMidSwap() async throws {
        let base = TestSupport.makeTempDir("syncrebind")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/repo",
                                                    withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/repo/seed.txt")

        // Slow-git wrapper: fetch sleeps 2 s (the rebind's swap window), the
        // first push sleeps 1 s (proves the setup loop is inside git), later
        // pushes sleep 3 s.
        let countFile = base + "/push-count"
        let wrapper = base + "/slow-git"
        let script = """
        #!/bin/sh
        for a in "$@"; do
          if [ "$a" = "fetch" ]; then sleep 2; break; fi
        done
        for a in "$@"; do
          if [ "$a" = "push" ]; then
            n=$(( $(cat '\(countFile)' 2>/dev/null || echo 0) + 1 ))
            echo "$n" > '\(countFile)'
            if [ "$n" -eq 1 ]; then sleep 1; else sleep 3; fi
            break
          fi
        done
        exec /usr/bin/git "$@"
        """
        TestSupport.write(script, to: wrapper)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                ofItemAtPath: wrapper)

        let repos = RepoManager(runner: GitRunner(gitExecutable: wrapper, defaultTimeout: 30))
        let sync = SyncManager(repoManager: repos, backoffSchedule: [0.1], maxAttempts: 1)
        let repo = base + "/repo"
        _ = try await repos.ensureRepo(at: repo)
        // First bind (absent remote): the tail enqueue starts the setup loop,
        // which enters its own slow push.
        try await sync.configureRemote(repoPath: repo, url: base + "/absent.git", autoPush: true)
        let start = Date()
        while Date().timeIntervalSince(start) < 10 {
            let n = (try? String(contentsOfFile: countFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if n == "1" { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Rebind while the setup loop's push is still in flight.
        let rebindDone = CompletionFlag()
        let rebind = Task.detached {
            _ = try? await sync.configureRemote(repoPath: repo, url: base + "/absent2.git",
                                                 autoPush: true)
            rebindDone.set()
        }
        // A commit lands while the rebind's fetch (2 s) is in flight.
        try? await Task.sleep(nanoseconds: 150_000_000)
        await sync.enqueuePush(repoPath: repo)

        // Sample inside the fetch window: a buggy mid-swap loop would have
        // bumped the counter to 2 by now (it started at ~0.2 s and pushed
        // immediately); the rebind itself cannot have finished yet.
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertFalse(rebindDone.isSet,
                       "sampling must happen while the rebind is still in flight")
        let n = (try? String(contentsOfFile: countFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(n, "1",
                       "a commit landing mid-rebind must not start a push to the OLD remote")
        let active = await sync.hasActivePushLoop(repoPath: repo)
        XCTAssertFalse(active,
                       "the rebind owns the push slot; its tail enqueue starts the loop after the swap")

        _ = try await rebind.value
        await sync.reset(repoPath: repo)
    }
}
