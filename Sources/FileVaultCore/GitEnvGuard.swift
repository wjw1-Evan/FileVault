import Foundation

/// Injectable protocol for locating a git executable.
public protocol GitLocator: Sendable {
    func locate() -> String?
}

/// Locates git from candidate paths, verifying each candidate actually runs.
public final class SystemGitLocator: GitLocator, @unchecked Sendable {
    public init() {}

    public func locate() -> String? {
        var candidates: [String] = []

        // 1. Bundled git (embedded in app bundle).
        if let res = Bundle.main.resourceURL?.appendingPathComponent("git").path {
            candidates.append(res)
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            candidates.append(execDir + "/git")
        }
        // 2. PATH lookup (which git).
        if let w = try? runWhich() {
            candidates.append(w)
        }
        // 3. Common install locations.
        candidates.append(contentsOf: [
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ])

        for c in candidates {
            if isExecutable(c) && verify(path: c) {
                return c
            }
        }
        return nil
    }

    private func runWhich() throws -> String? {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["git"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private func isExecutable(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IXUSR) != 0
    }

    /// Verify a candidate git actually executes and reports a version.
    private func verify(path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(decoding: data, as: UTF8.self)
            return p.terminationStatus == 0 && s.contains("git version")
        } catch {
            return false
        }
    }
}

/// Detects and prepares the git environment (FR-01).
public final class GitEnvGuard: @unchecked Sendable {
    public enum Status: Equatable {
        case notChecked
        case checking
        case ready(GitDetection)
        case failed(String)
    }

    public let locator: GitLocator
    public private(set) var status: Status = .notChecked
    public var onStatusChange: (@Sendable (Status) -> Void)?
    private let lock = NSLock()

    public init(locator: GitLocator = SystemGitLocator()) {
        self.locator = locator
    }

    private func setStatus(_ s: Status) {
        lock.lock()
        status = s
        lock.unlock()
        onStatusChange?(s)
    }

    /// Detect git. Returns .success(detection) or .failure when nothing usable.
    @discardableResult
    public func detect() async -> Result<GitDetection, Error> {
        setStatus(.checking)
        if let path = locator.locate() {
            let version = GitEnvGuard.version(fromExecutable: path) ?? "unknown"
            let d = GitDetection(gitPath: path, version: version, source: path.hasPrefix("/Applications") || path.hasPrefix(Bundle.main.bundlePath) ? .bundled : .system)
            setStatus(.ready(d))
            return .success(d)
        }
        setStatus(.failed("git not found"))
        return .failure(GitEnvError.notFound)
    }
}

public extension GitEnvGuard {
    /// Parse "git version X.Y.Z" output of `git --version`.
    static func version(fromExecutable path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(decoding: data, as: UTF8.self)
            guard p.terminationStatus == 0, let range = s.range(of: "git version ") else { return nil }
            return String(s[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Install strategy chain: bundled -> Xcode CLT trigger -> re-detect.
    /// The Xcode CLT installer shows the official system dialog (GUI flow).
    func install() async throws -> GitDetection {
        setStatus(.checking)
        defer { if case .checking = status { setStatus(.failed("install not completed")) } }

        // Strategy 1: bundled git shipped with the app (same approach as GitHub Desktop).
        if let res = Bundle.main.resourceURL?.appendingPathComponent("git").path,
           FileManager.default.isExecutableFile(atPath: res) {
            let version = GitEnvGuard.version(fromExecutable: res) ?? "unknown"
            let d = GitDetection(gitPath: res, version: version, source: .bundled)
            setStatus(.ready(d))
            return d
        }

        // Strategy 2: trigger the official Xcode CLT installer (system dialog).
        let clt = Process()
        clt.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        clt.arguments = ["--install"]
        clt.standardOutput = FileHandle.nullDevice
        clt.standardError = FileHandle.nullDevice
        try? clt.run()
        clt.waitUntilExit()

        // Re-detect after strategies ran.
        if let path = locator.locate() {
            let version = GitEnvGuard.version(fromExecutable: path) ?? "unknown"
            let d = GitDetection(gitPath: path, version: version, source: .system)
            setStatus(.ready(d))
            return d
        }
        throw GitEnvError.installFailed
    }
}

public enum GitEnvError: Error, LocalizedError {
    case notFound
    case installFailed

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "未找到可用的 git，请安装 Xcode Command Line Tools 后重试"
        case .installFailed:
            return "git 自动安装未完成，请手动安装后重试"
        }
    }
}
