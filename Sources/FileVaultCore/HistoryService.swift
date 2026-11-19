import Foundation

/// History browsing and rollback (FR-09/10).
public final class HistoryService: @unchecked Sendable {
    public let repoManager: RepoManager

    public init(repoManager: RepoManager) {
        self.repoManager = repoManager
    }

    /// Commits of a repo, newest first.
    public func commits(repoPath: String, limit: Int = 50, offset: Int = 0) async throws -> [CommitInfo] {
        try await repoManager.log(path: repoPath, max: limit, skip: offset)
    }

    /// Content of one file at a given commit.
    public func fileContent(repoPath: String, hash: String, file: String) async throws -> String {
        try RepoManager.validateRepoRelativePath(file)
        guard hash.range(of: "^[0-9a-fA-F]{4,40}$", options: .regularExpression) != nil else {
            throw HistoryError.commitNotFound(hash)
        }
        let r = try await repoManager.runner.run(["show", "\(hash):\(file)"], cwd: repoPath)
        guard r.succeeded else {
            throw GitCommandError(command: "show", exitCode: r.exitCode, stderr: r.stderr)
        }
        return r.stdout
    }

    /// Restore one file to a given commit and auto-commit the rollback (FR-10).
    public func restoreFile(repoPath: String, file: String, to hash: String) async throws -> String {
        try await repoManager.restoreFile(path: repoPath, file: file, to: hash)
    }

    /// Reset the whole repo to a given commit (FR-10, needs confirm in UI).
    public func resetRepo(repoPath: String, to hash: String) async throws {
        try await repoManager.resetRepo(path: repoPath, to: hash)
    }
}

public extension HistoryService {
    /// Changed files of one commit ("M\ta.md" style lines, FR-09 content view).
    /// Changed files of one commit as "status<TAB>path" lines.
    ///
    /// -z keeps unusual names (newlines, quotes, tabs) intact. Without it git
    /// C-quotes them into escaped pseudo-paths, so the changed list/preview/
    /// restore all operated on a path that does not exist (v4.2.26).
    /// Output shape with -z is status NUL path NUL (rename: R100 NUL old NUL new).
    /// --diff-merges=first-parent: a plain diff-tree prints NOTHING for merge
    /// commits, so every auto-sync merge showed "没有文件变更" and its files
    /// could not be browsed or restored (v4.2.28).
    func changedFiles(repoPath: String, hash: String) async throws -> [String] {
        let r = try await repoManager.runner.run(
            ["diff-tree", "--no-commit-id", "--name-status", "-r", "--root",
             "--diff-merges=first-parent", "-z", hash],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "diff-tree", exitCode: r.exitCode, stderr: r.stderr)
        }
        let tokens = r.stdout.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        var lines: [String] = []
        var index = 0
        while index < tokens.count {
            let status = tokens[index]
            index += 1
            guard index < tokens.count else { break }
            let path = tokens[index]
            index += 1
            var display = status + "\t" + path
            if status.hasPrefix("R") || status.hasPrefix("C"), index < tokens.count {
                let newPath = tokens[index]
                index += 1
                display = status + "\t" + path + " -> " + newPath
            }
            // The hidden marker only exists so Git can track folder creation;
            // it is an implementation detail, not a user-visible changed file.
            let lastComponent = (path as NSString).lastPathComponent
            if lastComponent != RepoManager.emptyFolderMarker {
                lines.append(display)
            }
        }
        return lines
    }
}

public extension HistoryService {
    /// COMPLETE file listing of one commit (v4.0.4 "full file tree").
    ///
    /// `changedFiles` only reports what the commit touched; this returns the whole
    /// snapshot, so files the commit did not modify can be browsed, previewed and
    /// restored too. `-z` disables git's path quoting (raw UTF-8, spaces and tabs
    /// stay literal), and records are "<mode> <type> <sha>\t<path>".
    /// The hidden `.gitkeep` folder marker is filtered out, as in changedFiles.
    func filesAtCommit(repoPath: String, hash: String,
                       limit: Int = 10_000) async throws -> CommitFileList {
        guard hash.range(of: "^[0-9a-fA-F]{4,40}$", options: .regularExpression) != nil else {
            throw HistoryError.commitNotFound(hash)
        }
        let r = try await repoManager.runner.run(
            ["ls-tree", "-r", "-z", "--full-tree", hash],
            cwd: repoPath
        )
        guard r.succeeded else {
            if r.stderr.contains("not a tree object") || r.stderr.contains("Not a valid object name") {
                throw HistoryError.commitNotFound(hash)
            }
            throw GitCommandError(command: "ls-tree", exitCode: r.exitCode, stderr: r.stderr)
        }
        let cap = max(1, limit)
        var entries: [CommitTreeEntry] = []
        var truncated = false
        for record in r.stdout.split(separator: "\u{0}", omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let meta = record[record.startIndex..<tab]
            let path = String(record[record.index(after: tab)...])
            guard !path.isEmpty else { continue }
            // Folder marker is an implementation detail, not a user-visible file.
            if (path as NSString).lastPathComponent == RepoManager.emptyFolderMarker { continue }
            if entries.count >= cap { truncated = true; break }
            let mode = String(meta.split(separator: " ").first ?? "")
            entries.append(CommitTreeEntry(path: path, mode: mode))
        }
        return CommitFileList(entries: entries, truncated: truncated)
    }

    /// Version timeline of ONE file: commits that touched it, newest first (v2.2.0).
    /// NUL-separated fields — see RepoManager.log (subject may contain "|").
    func fileHistory(repoPath: String, file: String, limit: Int = 100) async throws -> [CommitInfo] {
        let r = try await repoManager.runner.run(
            ["log", "--follow", "--pretty=format:%H%x00%h%x00%s%x00%aI", "-n", String(limit), "--", file],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "log --follow", exitCode: r.exitCode, stderr: r.stderr)
        }
        // One formatter for the whole batch (same reason as RepoManager.log).
        let f = ISO8601DateFormatter()
        return r.stdout.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\u{0}")
            guard parts.count == 4, !parts[0].isEmpty, !parts[3].isEmpty else { return nil }
            let d = f.date(from: parts[3]) ?? Date(timeIntervalSince1970: 0)
            return CommitInfo(hash: parts[0], shortHash: parts[1], subject: parts[2], date: d)
        }
    }
}

public extension HistoryService {
    /// Byte size of a file at `hash` (cheap: git cat-file -s).
    ///
    /// The history window uses this to decide whether to inline a text preview
    /// and whether a file is plausibly binary before loading the whole blob.
    func fileSize(repoPath: String, hash: String, file: String) async throws -> Int {
        try RepoManager.validateRepoRelativePath(file)
        guard hash.range(of: "^[0-9a-fA-F]{4,40}$", options: .regularExpression) != nil else {
            throw HistoryError.commitNotFound(hash)
        }
        let r = try await repoManager.runner.run(["cat-file", "-s", "\(hash):\(file)"], cwd: repoPath)
        guard r.succeeded else {
            throw HistoryError.fileNotInCommit(file: file, hash: String(hash.prefix(7)))
        }
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

public extension HistoryService {
    /// Write the file's content at `hash` to `destination` (binary-safe).
    ///
    /// v3.4.3: the history window can "open" a historical version of a file.
    /// `GitRunner` captures stdout as text (fine for diffs, lossy for images or
    /// PDFs), so the blob is streamed straight into a file handle here.
    /// Raw bytes of one file at the given commit (binary-safe; images, PDFs, ...).
    ///
    /// fileContent returns GitRunner's UTF-8 stdout, which is lossy for binary
    /// blobs. This pipes the exact blob into memory, reading before waiting so a
    /// full pipe buffer can never dead-lock the process.
    func fileData(repoPath: String, hash: String, file: String) async throws -> Data {
        try RepoManager.validateRepoRelativePath(file)
        guard hash.range(of: "^[0-9a-fA-F]{4,40}$", options: .regularExpression) != nil else {
            throw HistoryError.commitNotFound(hash)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: repoManager.runner.gitExecutable)
        // Match GitRunner: raw UTF-8 paths, and trust the folder this process
        // was asked about (external disks / another macOS account) — without
        // safe.directory the preview failed as "dubious ownership" (v4.2.25).
        process.arguments = ["-c", "core.quotepath=false",
                             "-c", "safe.directory=" + repoPath,
                             "-C", repoPath, "show", "\(hash):\(file)"]
        process.environment = Self.gitEnvironment(for: repoManager.runner)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw HistoryError.fileNotInCommit(file: file, hash: String(hash.prefix(7)))
        }
        // Drain stderr concurrently: reading it only after the child exits can
        // deadlock once git fills the 64 KB pipe buffer.
        let errLock = NSLock()
        var errData = Data()
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global().async {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            errLock.lock(); errData = d; errLock.unlock()
            errGroup.leave()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        Self.waitForDrain(errGroup)
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw detail.isEmpty
                ? HistoryError.fileNotInCommit(file: file, hash: String(hash.prefix(7)))
                : HistoryError.exportFailed(file: file)
        }
        return data
    }

    /// Bounded wait for a pipe-draining `DispatchGroup`. Wrapped in a
    /// synchronous helper so the `noasync` variant of `wait` is never called
    /// from an async context.
    private static func waitForDrain(_ group: DispatchGroup) {
        _ = group.wait(timeout: .now() + 5)
    }

    /// Environment for a direct git invocation: a bundled git needs GIT_EXEC_PATH
    /// and friends, which GitRunner carries but child Processes do not inherit.
    static func gitEnvironment(for runner: GitRunner) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in runner.baseEnvironment { env[key] = value }
        return env
    }

    func exportFile(repoPath: String, hash: String, file: String, to destination: URL) async throws {
        try RepoManager.validateRepoRelativePath(file)
        guard hash.range(of: "^[0-9a-fA-F]{4,40}$", options: .regularExpression) != nil else {
            throw HistoryError.commitNotFound(hash)
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw HistoryError.exportFailed(file: file)
        }
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: repoManager.runner.gitExecutable)
        process.arguments = ["-c", "core.quotepath=false",
                             "-c", "safe.directory=" + repoPath,
                             "-C", repoPath, "show", "\(hash):\(file)"]
        process.environment = Self.gitEnvironment(for: repoManager.runner)
        process.standardOutput = handle
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            // The empty destination was created moments ago and git never
            // wrote a byte: leaving it behind parked a 0-byte file with the
            // user's chosen name next to a "导出失败" message. Every other
            // failure branch below removes it; the spawn-failure path must
            // too.
            try? fm.removeItem(at: destination)
            throw HistoryError.exportFailed(file: file)
        }
        let errLock = NSLock()
        var errData = Data()
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global().async {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            errLock.lock(); errData = d; errLock.unlock()
            errGroup.leave()
        }
        process.waitUntilExit()
        Self.waitForDrain(errGroup)
        guard process.terminationStatus == 0 else {
            try? fm.removeItem(at: destination)
            let detail = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw detail.isEmpty
                ? HistoryError.fileNotInCommit(file: file, hash: String(hash.prefix(7)))
                : HistoryError.exportFailed(file: file)
        }
    }
}

