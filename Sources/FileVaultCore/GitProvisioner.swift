import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Architecture

/// CPU architecture of a downloadable git build.
public enum GitArch: String, Codable, Sendable {
    case arm64
    case x86_64

    /// Architecture the *host* can run natively (Rosetta-aware).
    ///
    /// An x86_64 build of FileVault launched under Rosetta on Apple silicon must
    /// still fetch the arm64 git payload, otherwise we would silently keep the
    /// user on an emulated toolchain.
    public static var current: GitArch {
        #if arch(arm64)
        return .arm64
        #else
        return hostSupportsAppleSilicon ? .arm64 : .x86_64
        #endif
    }

    static var hostSupportsAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return rc == 0 && value == 1
    }
}

// MARK: - Pinned builds

/// One pinned, checksum-verified git payload for a given architecture.
///
/// Pinning the exact asset (name + size + sha256) is what makes an unknown
/// mirror safe: a tampered or corrupt download is rejected before extraction.
public struct GitBuild: Codable, Equatable, Sendable {
    public var version: String
    public var tag: String
    public var asset: String
    public var sha256: String
    public var size: Int64
    public var arch: GitArch

    public init(version: String, tag: String, asset: String, sha256: String, size: Int64, arch: GitArch) {
        self.version = version
        self.tag = tag
        self.asset = asset
        self.sha256 = sha256
        self.size = size
        self.arch = arch
    }
}

/// The git binaries FileVault knows how to install (upstream: desktop/dugite-native,
/// the same payload GitHub Desktop ships). Bump this table in one place when a new
/// upstream release lands; tests assert the manifest stays internally consistent.
public enum GitBuildCatalog {
    /// darwin payloads are self-contained (git + curl + openssl + CA bundle).
    public static let appleSilicon = GitBuild(
        version: "2.56.1",
        tag: "v2.56.1",
        asset: "dugite-native-v2.56.1-238326e-macOS-arm64.tar.gz",
        sha256: "a882ec6882416b57d212a22bac845ae27944f96cf73453a864f6a12c17863a79",
        size: 63_505_330,
        arch: .arm64)

    public static let intel = GitBuild(
        version: "2.56.1",
        tag: "v2.56.1",
        asset: "dugite-native-v2.56.1-238326e-macOS-x64.tar.gz",
        sha256: "3fdb0c2f102fe0273d64b5d5fb77315c19f2b4648a154593723cb9ed98f2bc7d",
        size: 67_474_588,
        arch: .x86_64)

    public static let all: [GitBuild] = [appleSilicon, intel]

    public static func build(for arch: GitArch) -> GitBuild {
        arch == .arm64 ? appleSilicon : intel
    }
}

// MARK: - Mirrors

/// One download endpoint. `template` may contain `{version}`, `{tag}` and
/// `{asset}` placeholders, so a single ladder works for any pinned build.
public struct GitMirror: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var template: String

    public init(id: String, name: String, template: String) {
        self.id = id
        self.name = name
        self.template = template
    }

    /// Expand the template for `build`, returning nil when the URL cannot be formed.
    public func url(for build: GitBuild) -> URL? {
        var s = template
        s = s.replacingOccurrences(of: "{version}", with: build.version)
        s = s.replacingOccurrences(of: "{tag}", with: build.tag)
        s = s.replacingOccurrences(of: "{asset}", with: build.asset)
        guard let url = URL(string: s), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }
}

public extension GitMirror {
    /// Ordered fallback ladder.
    ///
    /// Order was measured on 2026-11-15 from a mainland-China network
    /// (no proxy): direct GitHub was fastest *when reachable*, the two
    /// accelerators backed it up for networks where github.com is blocked,
    /// and the project-owned release asset is the last resort under our own
    /// control. See docs/07-Git自动安装与镜像源.md for the measurement table.
    static let defaultLadder: [GitMirror] = [
        GitMirror(id: "github",
                  name: NSLocalizedString("GitHub 官方", comment: "git mirror name"),
                  template: "https://github.com/desktop/dugite-native/releases/download/{tag}/{asset}"),
        GitMirror(id: "ghfast",
                  name: NSLocalizedString("ghfast.top 加速", comment: "git mirror name"),
                  template: "https://ghfast.top/https://github.com/desktop/dugite-native/releases/download/{tag}/{asset}"),
        GitMirror(id: "gh-proxy",
                  name: NSLocalizedString("gh-proxy.com 加速", comment: "git mirror name"),
                  template: "https://gh-proxy.com/https://github.com/desktop/dugite-native/releases/download/{tag}/{asset}"),
        GitMirror(id: "ghproxy-cfd",
                  name: NSLocalizedString("ghproxy.cfd 加速", comment: "git mirror name"),
                  template: "https://ghproxy.cfd/https://github.com/desktop/dugite-native/releases/download/{tag}/{asset}"),
        // Project-owned mirror: the same payload re-published on FileVault's own
        // releases, so a dead third-party accelerator never leaves users stuck.
        GitMirror(id: "filevault",
                  name: NSLocalizedString("FileVault 自建镜像", comment: "git mirror name"),
                  template: "https://github.com/wjw1-Evan/FileVault/releases/download/git-{version}/{asset}"),
    ]
}

// MARK: - Progress

/// What the provisioner is currently doing (drives the menu bar status line).
public enum GitProvisionStage: String, Equatable, Sendable {
    case resolving      // picking a mirror
    case downloading    // bytes over the wire
    case verifying      // sha256 check
    case extracting     // untar into the support directory
    case validating     // `git --version` smoke test
    case ready          // done
}

public typealias GitProvisionProgress = @Sendable (GitProvisionStage, Double, String) -> Void

// MARK: - Transport seam

/// Byte transport for one download attempt. Injected so tests never touch the network.
public protocol GitDownloadTransport: Sendable {
    func download(from url: URL, to destination: URL, timeout: TimeInterval) async throws
}

/// Real transport: streaming URLSession download with an explicit timeout.
public struct URLSessionGitDownloadTransport: GitDownloadTransport {
    public init() {}

    public func download(from url: URL, to destination: URL, timeout: TimeInterval) async throws {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("FileVault/4.0 (macOS) git-provisioner", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (tempFile, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                throw GitProvisionError.httpStatus(http.statusCode)
            }
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: tempFile, to: destination)
    }
}

// MARK: - Errors

public enum GitProvisionError: Error, Equatable, LocalizedError {
    case unsupportedArch(GitArch)
    case noMirrors
    case httpStatus(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case extractFailed(String)
    case validationFailed(String)
    case timedOut
    case allMirrorsFailed(reasons: [String])

    public var errorDescription: String? {
        switch self {
        case .unsupportedArch(let arch):
            return String(format: NSLocalizedString("没有适用于 %@ 架构的 git 安装包", comment: "git provision error"), arch.rawValue)
        case .noMirrors:
            return NSLocalizedString("没有可用的 git 下载地址", comment: "git provision error")
        case .httpStatus(let code):
            return String(format: NSLocalizedString("下载失败（HTTP %d）", comment: "git provision error"), code)
        case .sizeMismatch(let expected, let actual):
            return String(format: NSLocalizedString("下载大小不匹配（期望 %lld 字节，实际 %lld 字节）", comment: "git provision error"), expected, actual)
        case .checksumMismatch:
            return NSLocalizedString("下载校验失败（sha256 不匹配，文件可能损坏或被篡改）", comment: "git provision error")
        case .extractFailed(let detail):
            return String(format: NSLocalizedString("解压 git 安装包失败：%@", comment: "git provision error"), detail)
        case .validationFailed(let detail):
            return String(format: NSLocalizedString("git 可执行文件校验失败：%@", comment: "git provision error"), detail)
        case .timedOut:
            return NSLocalizedString("下载超时（该地址太慢或被中断）", comment: "git provision error")
        case .allMirrorsFailed(let reasons):
            let head = String(format: NSLocalizedString("所有 git 下载地址都失败了（已尝试 %d 个）", comment: "git provision error"), reasons.count)
            return ([head] + reasons.map { "· \($0)" }).joined(separator: "\n")
        }
    }
}

// MARK: - Provisioner

/// Downloads, verifies and installs a self-contained git when the Mac has none.
///
/// Design goals, in order: never require the network when a bundled copy exists;
/// never trust a single mirror; never run an unverified binary.
public protocol GitProvisioning: Sendable {
    func provision(progress: GitProvisionProgress?) async throws -> String
}

public final class GitBinaryProvisioner: GitProvisioning, @unchecked Sendable {
    public let mirrors: [GitMirror]
    public let installRoot: URL
    /// Total budget for ONE mirror attempt before failing over to the next.
    public let attemptDeadline: TimeInterval
    /// Idle timeout: how long a stalled connection may sit at 0 bytes/s.
    public let idleTimeout: TimeInterval
    private let buildOverride: GitBuild?
    private let transport: GitDownloadTransport
    private let fileManager: FileManager

    /// ~/Library/Application Support/FileVault/git
    public static var defaultInstallRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("FileVault/git", isDirectory: true)
    }

    public init(build: GitBuild? = nil,
                mirrors: [GitMirror] = GitMirror.defaultLadder,
                transport: GitDownloadTransport = URLSessionGitDownloadTransport(),
                installRoot: URL = GitBinaryProvisioner.defaultInstallRoot,
                fileManager: FileManager = .default,
                attemptDeadline: TimeInterval = 600,
                idleTimeout: TimeInterval = 60) {
        self.buildOverride = build
        self.mirrors = mirrors
        self.transport = transport
        self.installRoot = installRoot
        self.fileManager = fileManager
        self.attemptDeadline = attemptDeadline
        self.idleTimeout = idleTimeout
    }

    /// The build this Mac needs.
    public var resolvedBuild: GitBuild? {
        buildOverride ?? GitBuildCatalog.build(for: GitArch.current)
    }

    /// Where a build is installed: <root>/<version>-<arch>
    public func targetDirectory(for build: GitBuild) -> URL {
        installRoot.appendingPathComponent("\(build.version)-\(build.arch.rawValue)", isDirectory: true)
    }

    public func gitExecutable(in directory: URL) -> String {
        directory.appendingPathComponent("bin/git").path
    }

    /// A previously provisioned, still-valid git (shared by locator + provision).
    public func installedGitPath() -> String? {
        guard let build = resolvedBuild else { return nil }
        let exe = gitExecutable(in: targetDirectory(for: build))
        guard Self.verifies(exe) else { return nil }
        return exe
    }

    // MARK: Provision

    public func provision(progress: GitProvisionProgress? = nil) async throws -> String {
        guard let build = resolvedBuild else {
            throw GitProvisionError.unsupportedArch(GitArch.current)
        }
        if let cached = installedGitPath() {
            progress?(.ready, 1, cached)
            return cached
        }
        guard !mirrors.isEmpty else { throw GitProvisionError.noMirrors }

        let fm = fileManager
        try? fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        let staging = installRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var reasons: [String] = []
        for (index, mirror) in mirrors.enumerated() {
            try Task.checkCancellation()
            guard let url = mirror.url(for: build) else {
                reasons.append("\(mirror.name): " + NSLocalizedString("地址无效", comment: "git mirror error"))
                continue
            }
            progress?(.resolving, Double(index) / Double(mirrors.count), mirror.name)
            let payload = staging.appendingPathComponent(build.asset)
            do {
                progress?(.downloading, 0, mirror.name)
                try await downloadWithDeadline(url, to: payload)

                progress?(.verifying, 0, mirror.name)
                try Self.verifyPayload(payload, build: build)

                let unboxed = staging.appendingPathComponent("unboxed", isDirectory: true)
                try? fm.removeItem(at: unboxed)
                try fm.createDirectory(at: unboxed, withIntermediateDirectories: true)

                progress?(.extracting, 0, mirror.name)
                try Self.extract(archive: payload, into: unboxed)
                guard let gitRoot = Self.locateGitRoot(in: unboxed) else {
                    throw GitProvisionError.extractFailed(
                        NSLocalizedString("压缩包内没有找到 git", comment: "git provision error"))
                }
                let candidate = gitRoot.appendingPathComponent("bin/git").path
                progress?(.validating, 0, mirror.name)
                guard Self.verifies(candidate) else {
                    throw GitProvisionError.validationFailed(
                        String(format: NSLocalizedString("git --version 无法执行：%@", comment: "git provision error"),
                               candidate))
                }
                try Self.pruneUnusedHelpers(in: gitRoot, fileManager: fm)
                try install(gitRoot, for: build)
                let final = gitExecutable(in: targetDirectory(for: build))
                guard Self.verifies(final) else {
                    throw GitProvisionError.validationFailed(
                        String(format: NSLocalizedString("安装后 git 无法执行：%@", comment: "git provision error"),
                               final))
                }
                progress?(.ready, 1, final)
                return final
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let mirrorLabel = NSLocalizedString(mirror.name, comment: "git mirror name")
                reasons.append("\(mirrorLabel): \(Self.shortReason(error))")
                try? fm.removeItem(at: payload)
            }
        }
        throw GitProvisionError.allMirrorsFailed(reasons: reasons)
    }

    /// Race one download against a hard per-mirror deadline: a mirror that stops
    /// making progress is abandoned so the next address gets a turn.
    private func downloadWithDeadline(_ url: URL, to destination: URL) async throws {
        let transport = self.transport
        let idle = self.idleTimeout
        let deadline = self.attemptDeadline
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await transport.download(from: url, to: destination, timeout: idle)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, deadline) * 1_000_000_000))
                throw GitProvisionError.timedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// The upstream payload also ships Git Credential Manager (a self-contained
    /// .NET/Avalonia GUI app, ~110 MB). FileVault never invokes it — credentials go
    /// through gh / keychain / SSH — so it is stripped after verification, keeping
    /// the installed payload at ~40 MB instead of ~150 MB.
    ///
    /// Safety rails: only runs when the GCM launcher is present (so the .NET files
    /// provably belong to it), only deletes inside libexec/git-core, and re-verifies
    /// git afterwards. Returns the number of removed files.
    @discardableResult
    public static func pruneUnusedHelpers(in gitRoot: URL, fileManager: FileManager = .default) throws -> Int {
        let core = gitRoot.appendingPathComponent("libexec/git-core", isDirectory: true)
        let fm = fileManager
        let gcm = core.appendingPathComponent("git-credential-manager")
        guard fm.fileExists(atPath: gcm.path) else { return 0 }

        let localeDirs: Set<String> = ["cs", "de", "es", "fr", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant"]
        let entries = (try? fm.contentsOfDirectory(at: core, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var removed = 0
        for entry in entries {
            let name = entry.lastPathComponent
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let isGCM: Bool
            if isDir {
                isGCM = localeDirs.contains(name)
            } else {
                isGCM = name.hasSuffix(".dll")
                    || name.hasSuffix(".dylib")
                    || name == "createdump"
                    || name.hasPrefix("git-credential-manager")
            }
            guard isGCM else { continue }
            if (try? fm.removeItem(at: entry)) != nil { removed += 1 }
        }
        guard removed > 0 else { return 0 }
        guard verifies(gitRoot.appendingPathComponent("bin/git").path) else {
            throw GitProvisionError.validationFailed(
                NSLocalizedString("移除非必需组件后 git 无法执行", comment: "git provision error"))
        }
        return removed
    }

    // MARK: Install / verify helpers

    private func install(_ gitRoot: URL, for build: GitBuild) throws {
        let fm = fileManager
        let target = targetDirectory(for: build)
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        // Same volume → atomic rename; fall back to a copy when it is not.
        do {
            try fm.moveItem(at: gitRoot, to: target)
        } catch {
            try fm.copyItem(at: gitRoot, to: target)
            try? fm.removeItem(at: gitRoot)
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gitExecutable(in: target))
    }

    /// Size + sha256 gate. Nothing is extracted before both pass.
    public static func verifyPayload(_ url: URL, build: GitBuild) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if build.size > 0, actualSize != build.size {
            throw GitProvisionError.sizeMismatch(expected: build.size, actual: actualSize)
        }
        let actual = try sha256(ofFile: url)
        guard actual.caseInsensitiveCompare(build.sha256) == .orderedSame else {
            throw GitProvisionError.checksumMismatch(expected: build.sha256, actual: actual)
        }
    }

    public static func sha256(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Untar with the system tar (no third-party dependency).
    static func extract(archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw GitProvisionError.extractFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitProvisionError.extractFailed(
                detail.isEmpty
                    ? String(format: NSLocalizedString("tar 退出码 %d", comment: "git provision error"),
                             process.terminationStatus)
                    : detail)
        }
    }

    /// Find the directory that contains `bin/git` (tarballs may or may not nest one level).
    static func locateGitRoot(in directory: URL) -> URL? {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent("bin/git")
        if fm.isExecutableFile(atPath: direct.path) { return directory }
        let entries = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            if fm.isExecutableFile(atPath: entry.appendingPathComponent("bin/git").path) { return entry }
        }
        return nil
    }

    /// Scan the install root for the newest still-working payload.
    /// Used by the locator so a previously provisioned git is found offline.
    public static func findInstalledGit(in root: URL = GitBinaryProvisioner.defaultInstallRoot) -> String? {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let exe = dir.appendingPathComponent("bin/git").path
            if verifies(exe) { return exe }
        }
        return nil
    }

    /// Run `git --version` and require a sane answer.
    public static func verifies(_ executable: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environmentOverrides(gitRoot: gitRoot(forExecutable: executable) ?? "") { env[k] = v }
        process.environment = env
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return process.terminationStatus == 0 && text.contains("git version")
    }

    /// "/x/git/bin/git" → "/x/git"; nil when the layout is not a self-contained payload.
    /// System gits (/usr/bin/git, Homebrew) are rejected so no bogus env is applied.
    public static func gitRoot(forExecutable path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardized
        guard url.lastPathComponent == "git",
              url.deletingLastPathComponent().lastPathComponent == "bin" else { return nil }
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        let markers = [
            root.appendingPathComponent("libexec/git-core").path,
            root.appendingPathComponent("share/git-core").path,
            root.appendingPathComponent("ssl/cacert.pem").path,
        ]
        guard markers.contains(where: { fm.fileExists(atPath: $0) }) else { return nil }
        return root.path
    }

    /// Environment a self-contained payload needs (its libexec / templates / CA bundle
    /// are not in the default locations, so plain `git` fails without these).
    public static func environmentOverrides(gitRoot: String) -> [String: String] {
        guard !gitRoot.isEmpty else { return [:] }
        let fm = FileManager.default
        var env: [String: String] = [:]
        let exec = gitRoot + "/libexec/git-core"
        if fm.fileExists(atPath: exec) { env["GIT_EXEC_PATH"] = exec }
        let templates = gitRoot + "/share/git-core/templates"
        if fm.fileExists(atPath: templates) { env["GIT_TEMPLATE_DIR"] = templates }
        let ca = gitRoot + "/ssl/cacert.pem"
        if fm.fileExists(atPath: ca) { env["GIT_SSL_CAINFO"] = ca }

        // The payload does not ship Apple's git-credential-osxkeychain helper.
        // When the Mac has Xcode / Command Line Tools, put its helper directory
        // on PATH so keychain credentials keep working with the bundled git.
        let helperDirs = [
            "/usr/libexec/git-core",
            "/Library/Developer/CommandLineTools/usr/libexec/git-core",
            "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core",
        ].filter { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        if !helperDirs.isEmpty {
            let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = (helperDirs + [existing]).joined(separator: ":")
        }
        return env
    }

    static func shortReason(_ error: Error) -> String {
        if let p = error as? GitProvisionError, let d = p.errorDescription { return d }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return NSLocalizedString("连接超时", comment: "git mirror error")
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return NSLocalizedString("DNS 解析失败", comment: "git mirror error")
            case NSURLErrorCannotConnectToHost: return NSLocalizedString("无法连接", comment: "git mirror error")
            case NSURLErrorNotConnectedToInternet: return NSLocalizedString("没有网络连接", comment: "git mirror error")
            case NSURLErrorNetworkConnectionLost: return NSLocalizedString("连接中断", comment: "git mirror error")
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted: return NSLocalizedString("TLS 握手失败", comment: "git mirror error")
            default: return ns.localizedDescription
            }
        }
        return ns.localizedDescription
    }
}
