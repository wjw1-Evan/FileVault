import Foundation

/// Commit history entry.
public struct CommitInfo: Codable, Equatable, Sendable {
    public var hash: String
    public var shortHash: String
    public var subject: String
    public var date: Date

    public init(hash: String, shortHash: String, subject: String, date: Date) {
        self.hash = hash
        self.shortHash = shortHash
        self.subject = subject
        self.date = date
    }
}

/// One changed path reported by `git status --porcelain`.
public struct StatusEntry: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case added
        case modified
        case deleted
        case renamed
        case typeChanged
        case other
    }

    public var change: Change
    public var path: String
    public var originalPath: String?   // for renames: "old -> new"

    public init(change: Change, path: String, originalPath: String? = nil) {
        self.change = change
        self.path = path
        self.originalPath = originalPath
    }

    public var displayName: String {
        let name = (path as NSString).lastPathComponent
        return name
    }
}

/// Repo scan result.
public struct SubRepo: Equatable, Sendable {
    public var name: String
    public var path: String
    public var isRepo: Bool

    public init(name: String, path: String, isRepo: Bool) {
        self.name = name
        self.path = path
        self.isRepo = isRepo
    }
}

/// Result of preparing repos under a root folder.
public struct RepoSetupResult: Equatable, Sendable {
    public var created: [String]
    public var adopted: [String]
    public var skippedHidden: Int

    public init(created: [String], adopted: [String], skippedHidden: Int) {
        self.created = created
        self.adopted = adopted
        self.skippedHidden = skippedHidden
    }
}

/// Git environment detection result.
public struct GitDetection: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case system
        case bundled
    }

    public var gitPath: String
    public var version: String
    public var source: Source

    public init(gitPath: String, version: String, source: Source) {
        self.gitPath = gitPath
        self.version = version
        self.source = source
    }
}

/// Sync status of one repo (menu bar display model).
public enum SyncStatus: String, Codable, Sendable {
    case noRemote
    case synced
    case pendingPush
    case pushing
    case failed
}
