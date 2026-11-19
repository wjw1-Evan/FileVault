import Foundation
import FileVaultCore

/// End-to-end core self-check (no UI): detect git, add root, auto-commit, push, rollback.
///
/// v4.0: the managed root IS the single repo — this exercises loose files at
/// the root, nested folders, and the whole-folder rollback.
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
            // FR-01 diagnostics: which layer supplied git (bundled / downloaded / system).
            if let det = service.detection {
                print("[SMOKE] git: \(det.gitPath) (\(det.version), source=\(det.source))")
            }
            // 2. add one root that contains a nested folder AND a loose file.
            let root = tmp + "/vault"
            try fm.createDirectory(atPath: root + "/lunwen", withIntermediateDirectories: true)
            try "root note".write(toFile: root + "/note.md", atomically: true, encoding: .utf8)
            try "v1".write(toFile: root + "/lunwen/a.md", atomically: true, encoding: .utf8)
            try await service.addRoot(path: root)
            check("root repo created", fm.fileExists(atPath: root + "/.git"))
            check("no nested repo", !fm.fileExists(atPath: root + "/lunwen/.git"))
            // Loose root files and nested files are both tracked.
            let tracked = await service.repoManager.listFiles(path: root)
            check("root-level file tracked", tracked.contains("note.md"))
            check("nested file tracked", tracked.contains("lunwen/a.md"))
            // 3. write -> auto commit (default debounce 5s; wait up to 15s)
            try "v2".write(toFile: root + "/lunwen/a.md", atomically: true, encoding: .utf8)
            var commits: [CommitInfo] = []
            var waited = 0.0
            while waited < 15.0 {
                commits = (try? await service.repoManager.log(path: root, max: 10)) ?? []
                if commits.count >= 2 { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 0.5
            }
            check("auto commit fired", commits.count >= 2)
            // 4. auto-push to a local bare remote
            let remote = tmp + "/remote.git"
            guard let git = service.detection?.gitPath else {
                check("git path available", false)
                return false
            }
            let runner = GitRunner.forExecutable(git)
            // Explicit branch: Apple git defaults a bare repo to "main", the bundled
            // payload to "master" — FileVault always creates repos on "main".
            _ = try? await runner.run(["init", "--bare", "-b", "main", remote])
            try await service.sync.configureRemote(repoPath: root, url: remote, autoPush: true)
            var pushed = false
            for _ in 0..<20 {
                if await service.sync.status(for: root) == .synced { pushed = true; break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let remoteLog = try? await GitRunner.forExecutable(git).run(["--git-dir=" + remote, "log", "--oneline", "-n", "1"])
            check("auto-push to bare remote", pushed && (remoteLog?.succeeded ?? false))
            // 5. rollback the WHOLE root to the first commit and verify content
            try "v3".write(toFile: root + "/lunwen/a.md", atomically: true, encoding: .utf8)
            var logs: [CommitInfo] = []
            var waited2 = 0.0
            while waited2 < 20.0 {
                logs = (try? await service.repoManager.log(path: root, max: 10)) ?? []
                if logs.count >= 3 { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited2 += 0.5
            }
            print("[SMOKE][debug] commits=\(logs.count) subjects=\(logs.map(\.subject))")
            // 5.5 complete file tree of the newest commit (v4.0.4): files the
            // commit did not touch must still be listed and readable.
            if let head = logs.first {
                let list = (try? await service.history.filesAtCommit(repoPath: root, hash: head.hash)) ?? CommitFileList(entries: [])
                let paths = Set(list.entries.map(\.path))
                check("full tree lists untouched files",
                      paths.contains("note.md") && paths.contains("lunwen/a.md"))
                let note = try? await service.history.fileContent(repoPath: root, hash: head.hash, file: "note.md")
                check("full tree file readable", note == "root note")
            }
            // Roll the WHOLE folder back to its oldest commit (the initial
            // version captured at addRoot) and verify the nested file is v1.
            if let first = logs.last, logs.count >= 2 {
                try await service.history.resetRepo(repoPath: root, to: first.hash)
                let content = (try? String(contentsOfFile: root + "/lunwen/a.md", encoding: .utf8)) ?? ""
                check("rollback works", content == "v1")
            } else {
                check("rollback works", logs.count >= 2)
            }
            // 6. config persistence
            let cfg = service.configStore.load()
            // URL(fileURLWithPath:) is infallible and resolvingSymlinksInPath()
            // never throws — the old try? only silenced a phantom error (v4.2.31).
            let rootResolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
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
