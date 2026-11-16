import Foundation

/// Result of one git command execution.
public struct GitResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }
}

/// Error thrown when a git command fails.
///
/// Conforms to `LocalizedError` (v4.1.1). It used to expose `errorDescription`
/// without the protocol, so every UI path that renders
/// `error.localizedDescription` fell back to Foundation's generic text
/// ("The operation couldn't be completed. (FileVaultCore.GitCommandError error 1.)").
public struct GitCommandError: Error, LocalizedError, Sendable, Equatable {
    public let command: String
    public let exitCode: Int32
    public let stderr: String

    public var errorDescription: String? {
        let detail = PullError.condense(stderr)
        guard !detail.isEmpty else {
            return String(format: NSLocalizedString("git %@ 执行失败（退出码 %d）", comment: "git error"),
                          command, exitCode)
        }
        return String(format: NSLocalizedString("git %@ 执行失败（退出码 %d）：%@", comment: "git error"),
                      command, exitCode, detail)
    }
}

/// Thin wrapper that executes git via `Process` with timeout and output capture.
public final class GitRunner: Sendable {
    public let gitExecutable: String
    public let defaultTimeout: TimeInterval
    /// Environment a self-contained git payload needs (GIT_EXEC_PATH, CA bundle, …).
    /// Applied to every invocation; per-call env wins over these defaults.
    public let baseEnvironment: [String: String]

    public init(gitExecutable: String, defaultTimeout: TimeInterval = 30, baseEnvironment: [String: String] = [:]) {
        self.gitExecutable = gitExecutable
        self.defaultTimeout = defaultTimeout
        self.baseEnvironment = baseEnvironment
    }

    /// Runner for a located git, automatically carrying the environment a
    /// self-contained payload (bundled / downloaded) needs. System git gets the
    /// plain environment, so behaviour there is unchanged.
    public static func forExecutable(_ gitPath: String, defaultTimeout: TimeInterval = 30) -> GitRunner {
        if let root = GitBinaryProvisioner.gitRoot(forExecutable: gitPath) {
            return GitRunner(gitExecutable: gitPath, defaultTimeout: defaultTimeout,
                             baseEnvironment: GitBinaryProvisioner.environmentOverrides(gitRoot: root))
        }
        return GitRunner(gitExecutable: gitPath, defaultTimeout: defaultTimeout)
    }

    /// Run git with args. Async wrapper over the synchronous implementation.
    public func run(_ args: [String], cwd: String? = nil, timeout: TimeInterval? = nil, stdin: String? = nil, env: [String: String]? = nil) async throws -> GitResult {
        let t = timeout ?? defaultTimeout
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do {
                    let r = try self.runSync(args, cwd: cwd, timeout: t, stdin: stdin, env: env)
                    cont.resume(returning: r)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous execution with timeout. Safe to call from any thread.
    public func runSync(_ args: [String], cwd: String? = nil, timeout: TimeInterval, stdin: String? = nil, env: [String: String]? = nil) throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitExecutable)
        // Raw UTF-8 paths everywhere: git quotes non-ASCII paths as octal
        // escapes by default ("笔记/\346..." style), which shows up as garbled
        // filenames in the history window and breaks downstream path handling
        // (v2.6.2). `-c` before the subcommand applies to every invocation.
        //
        // safe.directory (v4.1.10): folders on external disks or created by
        // another macOS account are owned by a different user, and git refuses
        // ALL commands with "dubious ownership". FileVault only ever operates on
        // folders the user explicitly added, so trusting that folder for this
        // process (command-line scope, NOT the user's global config) is right.
        var execArgs = ["-c", "core.quotepath=false"]
        if let cwd, !cwd.isEmpty {
            execArgs += ["-c", "safe.directory=" + cwd]
        }
        process.arguments = execArgs + args

        var e = ProcessInfo.processInfo.environment
        // Self-contained payloads (bundled/downloaded git) keep their libexec,
        // templates and CA bundle outside the system paths.
        for (k, v) in baseEnvironment { e[k] = v }
        // FileVault has no terminal: a missing credential or SSH passphrase must
        // fail fast with a readable error instead of hanging (or popping a GUI
        // askpass) in the background (v4.2.3). Users can still override these
        // through their own environment or git config (core.sshCommand).
        if e["GIT_TERMINAL_PROMPT"] == nil { e["GIT_TERMINAL_PROMPT"] = "0" }
        if e["GIT_SSH_COMMAND"] == nil {
            e["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=20"
        }
        // Make sure the git executable's directory is on PATH so that
        // credential helpers / hooks / ssh can be resolved.
        let gitDir = (gitExecutable as NSString).deletingLastPathComponent
        e["PATH"] = gitDir + ":" + (e["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        for (k, v) in env ?? [:] { e[k] = v }
        process.environment = e

        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let group = DispatchGroup()
        let lock = NSLock()
        var outData = Data()
        var errData = Data()

        group.enter()
        DispatchQueue.global().async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = d; lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = d; lock.unlock()
            group.leave()
        }

        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        do {
            try process.run()
        } catch {
            // The pipe readers above are ALREADY waiting for EOF. If the spawn
            // fails, nothing will ever close the write ends and both global-
            // queue threads block forever — 64 of those and GCD hits its soft
            // limit, starving the whole process under load (full-suite hang).
            outPipe.fileHandleForWriting.closeFile()
            errPipe.fileHandleForWriting.closeFile()
            throw error
        }

        let exitSem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSem.signal() }

        let waitResult = exitSem.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            process.terminate()
            _ = exitSem.wait(timeout: .now() + 5)
            throw GitCommandError(command: args.joined(separator: " "), exitCode: -9, stderr: "git command timed out after \(timeout)s")
        }

        // Defense in depth: normally EOF arrives as soon as the child exits.
        // If some fd-holding descendant keeps the pipes open, proceed with the
        // captured data instead of deadlocking a global-queue thread forever.
        if group.wait(timeout: .now() + 10) == .timedOut {
            outPipe.fileHandleForWriting.closeFile()
            errPipe.fileHandleForWriting.closeFile()
            _ = group.wait(timeout: .now() + 2)
        }
        process.terminationHandler = nil

        return GitResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
    /// One-time `gh auth setup-git` so GitHub HTTPS pushes work without manual
    /// credential setup (idempotent).
    public static func ghAuthSetupGit() async {
        let gh = SelfUpdater.ghURL()
        guard FileManager.default.isExecutableFile(atPath: gh.path) else { return }
        let p = Process()
        p.executableURL = gh
        p.arguments = ["auth", "setup-git"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

}