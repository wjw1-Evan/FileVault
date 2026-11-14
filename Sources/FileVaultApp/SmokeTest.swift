import Foundation
import FileVaultCore

/// End-to-end core self-check (no UI): detect git, add root, auto-commit, push, rollback.
enum SmokeTest {
    static func run() -> Bool {
        let sema = DispatchSemaphore(value: 0)
        var ok = true
        Task {
            ok = await runAsync()
            sema.signal()
        }
        sema.wait()
        return ok
    }

    private static func runAsync() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) {
            let mark = cond ? "PASS" : "FAIL"
            print("[SMOKE][\(mark)] \(name)")
            if !cond { ok = false }
        }
        let tmp = NSTemporaryDirectory().appending("fv-smoke-\(Int(Date().timeIntervalSince1970))")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: tmp + "/config"))
        do {
            try await service.start()
            check("git detected", service.detection != nil)
            // 2. add root with two subfolders
            let root = tmp + "/vault"
            try fm.createDirectory(atPath: root + "/lunwen", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: root + "/sheji", withIntermediateDirectories: true)
            try await service.addRoot(path: root)
            check("repos created", fm.fileExists(atPath: root + "/lunwen/.git") && fm.fileExists(atPath: root + "/sheji/.git"))
            // 3. write -> auto commit (default debounce 5s; wait up to 12s)
            try "v1".write(toFile: root + "/lunwen/a.md", atomically: true, encoding: .utf8)
            var commits: [CommitInfo] = []
            var waited = 0.0
            while waited < 15.0 {
                commits = (try? await service.repoManager.log(path: root + "/lunwen", max: 10)) ?? []
                if commits.count >= 2 { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 0.5
            }
            check("auto commit fired", commits.count >= 2)
            // 4. auto-push to a local bare remote
            let remote = tmp + "/remote.git"
            let git = service.detection!.gitPath
            let runner = GitRunner(gitExecutable: git)
            _ = try? await runner.run(["init", "--bare", remote])
            try await service.sync.configureRemote(repoPath: root + "/lunwen", url: remote, autoPush: true)
            var pushed = false
            for _ in 0..<20 {
                if await service.sync.status(for: root + "/lunwen") == .synced { pushed = true; break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let remoteLog = try? await GitRunner(gitExecutable: git).run(["--git-dir=" + remote, "log", "--oneline", "-n", "1"])
            check("auto-push to bare remote", pushed && (remoteLog?.succeeded ?? false))
            // 5. rollback to the first commit and verify content
            try "v2".write(toFile: root + "/lunwen/a.md", atomically: true, encoding: .utf8)
            var logs: [CommitInfo] = []
            var waited2 = 0.0
            while waited2 < 20.0 {
                logs = (try? await service.repoManager.log(path: root + "/lunwen", max: 10)) ?? []
                if logs.count >= 3 { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited2 += 0.5
            }
            print("[SMOKE][debug] commits=\(logs.count) subjects=\(logs.map(\.subject))")
            if logs.count >= 2 {
                let old = logs[logs.count - 2]
                try await service.history.resetRepo(repoPath: root + "/lunwen", to: old.hash)
                let content = (try? String(contentsOfFile: root + "/lunwen/a.md", encoding: .utf8)) ?? ""
                check("rollback works", content == "v1")
            } else {
                check("rollback works", logs.count >= 2)
            }
            // 6. config persistence
            let cfg = service.configStore.load()
            let rootResolved = try? URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            check("config persisted", cfg.roots.contains { $0.path == rootResolved })
            if !ok { print("[SMOKE][debug] kept for inspection: \(tmp)") } else { try? fm.removeItem(atPath: tmp) }
        } catch {
            print("[SMOKE][FAIL] exception: \(error)")
            ok = false
        }
        print(ok ? "SMOKE OK" : "SMOKE FAILED")
        return ok
    }
}
