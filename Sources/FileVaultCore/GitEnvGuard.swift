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

        // 1. Bundled git (embedded in app bundle, zero network).
        if let res = Bundle.main.resourceURL?.appendingPathComponent("git").path {
            candidates.append(res + "/bin/git")
            candidates.append(res)
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            candidates.append(execDir + "/git")
        }
        // 2. git provisioned on a previous launch (downloaded + checksum-pinned).
        if let provisioned = GitBinaryProvisioner.findInstalledGit() {
            candidates.append(provisioned)
        }
        // 3. PATH lookup (which git).
        if let w = try? runWhich() {
            candidates.append(w)
        }
        // 4. Common install locations.
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
        GitBinaryProvisioner.verifies(path)
    }
}

/// Injectable installer seam (tests use fakes; the real path downloads or shells out).
public protocol GitInstalling: Sendable {
    func install() async throws -> GitDetection
}

extension GitEnvGuard: GitInstalling {}

/// Detects and prepares the git environment (FR-01).
public final class GitEnvGuard: @unchecked Sendable {
    public enum Status: Equatable {
        case notChecked
        case checking
        case ready(GitDetection)
        case failed(String)
    }

    public enum InstallStrategy: Equatable, Sendable {
        case none
        case bundled
        case downloaded
        case xcodeCLT
    }

    public let locator: GitLocator
    /// Downloads a checksum-pinned git from the mirror ladder; nil disables it (tests).
    public let provisioner: GitProvisioning?
    /// Whether the last-resort Xcode Command Line Tools dialog may be triggered.
    /// Disabled in tests: the dialog is modal and downloads ~1.5 GB.
    public let allowXcodeCLTFallback: Bool
    public private(set) var status: Status = .notChecked
    /// Last strategy used by install() — diagnostics / support bundle.
    public private(set) var lastStrategy: InstallStrategy = .none
    public var onStatusChange: (@Sendable (Status) -> Void)?
    /// Mirror download progress: stage, fraction, mirror name.
    public var onInstallProgress: GitProvisionProgress?
    private let lock = NSLock()

    public init(locator: GitLocator = SystemGitLocator(),
                provisioner: GitProvisioning? = GitBinaryProvisioner(),
                allowXcodeCLTFallback: Bool = true) {
        self.locator = locator
        self.provisioner = provisioner
        self.allowXcodeCLTFallback = allowXcodeCLTFallback
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
            let d = GitDetection(gitPath: path, version: version, source: GitEnvGuard.source(for: path))
            setStatus(.ready(d))
            return .success(d)
        }
        setStatus(.failed("git not found"))
        return .failure(GitEnvError.notFound)
    }

    /// Classify a located git so diagnostics and the UI can tell where it came from.
    public static func source(for path: String) -> GitDetection.Source {
        let standardized = URL(fileURLWithPath: path).standardized.path
        let bundle = Bundle.main.bundlePath
        if !bundle.isEmpty, standardized.hasPrefix(bundle + "/") { return .bundled }
        let provisioned = GitBinaryProvisioner.defaultInstallRoot.path
        if standardized.hasPrefix(provisioned + "/") { return .downloaded }
        return .system
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

    /// Install strategy chain (FR-01):
    ///
    /// 1. bundled  — git shipped inside the app bundle (no network at all).
    /// 2. downloaded — checksum-pinned payload from the mirror ladder
    ///    (GitHub -> accelerators -> project mirror), sha256-verified before use.
    /// 3. Xcode CLT — last resort: Apple dialog + ~1.5 GB download.
    ///
    /// Each step re-detects before moving on, so a working git is never downloaded again.
    func install() async throws -> GitDetection {
        setStatus(.checking)
        defer { if case .checking = status { setStatus(.failed("install not completed")) } }

        // Strategy 1: bundled git shipped with the app (same approach as GitHub Desktop).
        if let bundled = Self.bundledGitPath() {
            let version = GitEnvGuard.version(fromExecutable: bundled) ?? "unknown"
            let d = GitDetection(gitPath: bundled, version: version, source: .bundled)
            lastStrategy = .bundled
            setStatus(.ready(d))
            return d
        }
        if let path = locator.locate() {
            let d = GitDetection(gitPath: path, version: GitEnvGuard.version(fromExecutable: path) ?? "unknown",
                                 source: GitEnvGuard.source(for: path))
            lastStrategy = d.source == .downloaded ? .downloaded : .none
            setStatus(.ready(d))
            return d
        }

        // Strategy 2: download a self-contained git from the mirror ladder.
        var downloadFailure: Error?
        if let provisioner {
            do {
                let path = try await provisioner.provision(progress: onInstallProgress)
                lastStrategy = .downloaded
                let d = GitDetection(gitPath: path, version: GitEnvGuard.version(fromExecutable: path) ?? "unknown",
                                     source: GitEnvGuard.source(for: path))
                setStatus(.ready(d))
                return d
            } catch {
                downloadFailure = error
            }
        }

        // Strategy 3: trigger the official Xcode CLT installer (system dialog, ~1.5 GB).
        if allowXcodeCLTFallback {
            lastStrategy = .xcodeCLT
            let clt = Process()
            clt.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            clt.arguments = ["--install"]
            clt.standardOutput = FileHandle.nullDevice
            clt.standardError = FileHandle.nullDevice
            try? clt.run()
            clt.waitUntilExit()
        }

        if let path = locator.locate() {
            let d = GitDetection(gitPath: path, version: GitEnvGuard.version(fromExecutable: path) ?? "unknown",
                                 source: GitEnvGuard.source(for: path))
            setStatus(.ready(d))
            return d
        }
        if let downloadFailure {
            throw GitEnvError.provisionFailed(downloadFailure.localizedDescription)
        }
        throw GitEnvError.installFailed
    }

    /// Path to a git payload shipped inside the app bundle, if present.
    static func bundledGitPath(bundle: Bundle = .main) -> String? {
        guard let res = bundle.resourceURL else { return nil }
        // Only the packaged layout counts: Contents/Resources/git/bin/git.
        // A bare "Resources/git" must NOT be accepted — on a Mac with Xcode that
        // path can be Xcode's own developer git, which is not ours to claim.
        let candidates = [
            res.appendingPathComponent("git/bin/git").path,
        ]
        for c in candidates where GitBinaryProvisioner.verifies(c) {
            return c
        }
        return nil
    }
}

public enum GitEnvError: Error, LocalizedError {
    case notFound
    case installFailed
    case provisionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return NSLocalizedString("未找到可用的 git，请安装 Xcode Command Line Tools 后重试", comment: "git setup error")
        case .installFailed:
            return NSLocalizedString("git 自动安装未完成，请手动安装后重试", comment: "git setup error")
        case .provisionFailed(let detail):
            return String(format: NSLocalizedString("git 自动下载安装失败（已逐个尝试备用下载地址）。\n%@\n可以在「设置 → 诊断」导出诊断包，或手动安装 Xcode Command Line Tools 后重启应用。", comment: "git setup error"), detail)
        }
    }
}
