import Foundation

/// Commit history entry.
public struct CommitInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String { hash }
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

/// Result of preparing ONE managed root folder as a Git repository.
///
/// v4.0: a managed root is exactly one repository — the root itself. There is
/// no per-subfolder repository concept anymore, so the result is a single
/// outcome instead of lists of created/adopted subrepos.
public struct RepoSetupResult: Equatable, Sendable {
    /// True when the root had no repository and one was created (git init).
    public var created: Bool
    /// True when an existing repository in the root was adopted untouched.
    public var adopted: Bool

    public init(created: Bool = false, adopted: Bool = false) {
        self.created = created
        self.adopted = adopted
    }
}

/// Git environment detection result.
public struct GitDetection: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case system
        case bundled
        /// Provisioned at first launch from a verified download mirror (FR-01).
        case downloaded
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

/// Thread-safe mutable callback holder (usable from actors).
public final class EventCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: (@Sendable (String, String) -> Void)?
    public init() {}
    public var handler: (@Sendable (String, String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }
    public func callAsFunction(_ a: String, _ b: String) {
        lock.lock(); let h = _handler; lock.unlock()
        h?(a, b)
    }
}
