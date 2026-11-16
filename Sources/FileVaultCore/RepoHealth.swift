import Foundation

/// Repo health snapshot (FR-19).
public struct RepoHealth: Equatable, Sendable {
    public var commitCount: Int
    public var sizeBytes: UInt64
    public var lastCommitDate: Date?
    /// Files that were auto-excluded because they exceed the remote's single
    /// file limit — they are NOT backed up, so the UI must surface them.
    public var excludedLargeFileCount: Int
    /// False when the folder is gone (external disk unmounted, folder moved)
    /// or is no longer a git repository: the card must say so instead of
    /// showing a misleading "0 commits · 0KB" (v4.2.8).
    public var available: Bool
    /// Set when git reads failed (rev-list/log): the health line must show the
    /// failure instead of a misleading "0 次提交" (v4.2.27).
    public var readError: String?

    public init(commitCount: Int, sizeBytes: UInt64, lastCommitDate: Date?,
                excludedLargeFileCount: Int = 0, available: Bool = true,
                readError: String? = nil) {
        self.commitCount = commitCount
        self.sizeBytes = sizeBytes
        self.lastCommitDate = lastCommitDate
        self.excludedLargeFileCount = excludedLargeFileCount
        self.available = available
        self.readError = readError
    }

    public var summary: String {
        guard available else {
            return NSLocalizedString("⚠️ 文件夹当前不可用（可能未挂载或被移动）", comment: "repo health")
        }
        if let readError {
            return NSLocalizedString("⚠️ 仓库读取失败", comment: "repo health") + "：" + readError
        }
        var t = commitCount == 1
            ? String(format: NSLocalizedString("1 次提交 · %@", comment: "repo health"), sizeText)
            : String(format: NSLocalizedString("%d 次提交 · %@", comment: "repo health"), commitCount, sizeText)
        if let d = lastCommitDate {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            t += String(format: NSLocalizedString(" · 最近 %@", comment: "repo health"), f.string(from: d))
        }
        if sizeBytes > RepoManager.repoSizeWarningThreshold {
            t += NSLocalizedString(" · ⚠️ 超过 2GB", comment: "repo health")
        }
        if excludedLargeFileCount > 0 {
            t += String(format: NSLocalizedString(" · ⚠️ %d 个大文件未同步", comment: "repo health"),
                        excludedLargeFileCount)
        }
        return t
    }

    public var sizeText: String {
        let mb = Double(sizeBytes) / 1024 / 1024
        if mb >= 1024 {
            return String(format: "%.1fGB", mb / 1024)
        }
        if mb >= 1 {
            return String(format: "%.0fMB", mb)
        }
        return String(format: "%.0fKB", Double(sizeBytes) / 1024)
    }
}

public extension RepoManager {
    /// Repo health: commit count, .git size, last commit date (FR-19).
    func health(path: String) async -> RepoHealth {
        guard isRepo(at: path) else {
            return RepoHealth(commitCount: 0, sizeBytes: 0, lastCommitDate: nil, available: false)
        }
        let gitDir = RepoManager.gitDirectory(forRepoAt: path)
        var size: UInt64 = 0
        if let e = FileManager.default.enumerator(atPath: gitDir) {
            for case let f as String in e {
                let full = (gitDir as NSString).appendingPathComponent(f)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                   let s = attrs[.size] as? UInt64 {
                    size += s
                }
            }
        }
        let countResult = try? await runner.run(["rev-list", "--count", "HEAD"], cwd: path)
        let count = countResult.flatMap { Int($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let log = (try? await self.log(path: path, max: 1)) ?? []
        // A failed read is an error, not "0 commits" — EXCEPT an unborn HEAD
        // (fresh repo), which is genuinely empty (v4.2.27).
        var readError: String?
        if countResult?.succeeded != true,
           !(countResult?.stderr.contains("unknown revision") ?? false),
           !(countResult?.stderr.contains("does not have any commits yet") ?? false) {
            readError = "rev-list exit \((countResult?.exitCode ?? -1))"
        }
        let excluded = self.excludedLargeFiles(path: path).count
        return RepoHealth(commitCount: count, sizeBytes: size, lastCommitDate: log.first?.date,
                          excludedLargeFileCount: excluded, readError: readError)
    }
}

public extension RepoManager {
    /// Repository size threshold for warnings (2GB per PRD).
    static let repoSizeWarningThreshold: UInt64 = 2 * 1024 * 1024 * 1024
    /// Default maintenance interval: 7 days (weekly gc).
    static let defaultGcInterval: TimeInterval = 7 * 24 * 3600

    /// Weekly `git gc --auto` with a marker file in .git (FR-19).
    /// Returns true when gc actually ran.
    @discardableResult
    func runMaintenanceIfNeeded(path: String, interval: TimeInterval = RepoManager.defaultGcInterval) async -> Bool {
        // Resolve the REAL git dir: a worktree/linked checkout has .git as a
        // FILE, and writing the marker into "<path>/.git/..." either failed or
        // re-ran gc on every launch (v4.2.26).
        let gitDir = RepoManager.gitDirectory(forRepoAt: path)
        let marker = (gitDir as NSString).appendingPathComponent("filevault-last-gc")
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        if let attrs = try? fm.attributesOfItem(atPath: marker),
           let t = attrs[.modificationDate] as? Date,
           now - t.timeIntervalSince1970 < interval {
            return false
        }
        // Only record a successful gc: a failed run used to be remembered for a
        // whole week, so maintenance never retried (v4.2.26).
        guard let gc = try? await runner.run(["gc", "--auto", "--quiet"], cwd: path),
              gc.succeeded else { return false }
        fm.createFile(atPath: marker, contents: Data(String(now).utf8), attributes: nil)
        return true
    }
}
