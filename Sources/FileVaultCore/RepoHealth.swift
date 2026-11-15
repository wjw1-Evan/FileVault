import Foundation

/// Repo health snapshot (FR-19).
public struct RepoHealth: Equatable, Sendable {
    public var commitCount: Int
    public var sizeBytes: UInt64
    public var lastCommitDate: Date?

    public init(commitCount: Int, sizeBytes: UInt64, lastCommitDate: Date?) {
        self.commitCount = commitCount
        self.sizeBytes = sizeBytes
        self.lastCommitDate = lastCommitDate
    }

    public var summary: String {
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
        let gitDir = (path as NSString).appendingPathComponent(".git")
        var size: UInt64 = 0
        if let e = FileManager.default.enumerator(atPath: gitDir) {
            for f in e {
                let full = (gitDir as NSString).appendingPathComponent(f as! String)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                   let s = attrs[.size] as? UInt64 {
                    size += s
                }
            }
        }
        let countResult = try? await runner.run(["rev-list", "--count", "HEAD"], cwd: path)
        let count = countResult.flatMap { Int($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let log = (try? await self.log(path: path, max: 1)) ?? []
        return RepoHealth(commitCount: count, sizeBytes: size, lastCommitDate: log.first?.date)
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
        let marker = (path as NSString).appendingPathComponent(".git/filevault-last-gc")
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        if let attrs = try? fm.attributesOfItem(atPath: marker),
           let t = attrs[.modificationDate] as? Date,
           now - t.timeIntervalSince1970 < interval {
            return false
        }
        _ = try? await runner.run(["gc", "--auto", "--quiet"], cwd: path)
        fm.createFile(atPath: marker, contents: Data(String(now).utf8), attributes: nil)
        return true
    }
}
