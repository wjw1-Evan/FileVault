import Foundation
#if canImport(Darwin)
import Darwin
#endif

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
        // Every path FileVault passes to git is a LITERAL file name, never a
        // pattern: with default pathspec rules a file named "a[1].txt" also
        // matches "a1.txt", so restoring one file could rewrite its siblings and
        // "*.md" would match every markdown file (v4.2.26). This global flag
        // disables globbing/pathspec magic for the whole process while keeping
        // normal directory-prefix matching (verified: add -A, checkout/rm/diff/
        // log with a directory still operate on the directory).
        // check-ignore REJECTS the literal pathspec magic (it errors out), so the
        // global flag must be omitted there; its arguments are plain pathnames and
        // are already matched literally.
        let subcommand = args.first ?? ""
        var execArgs = subcommand == "check-ignore"
            ? ["-c", "core.quotepath=false"]
            : ["--literal-pathspecs", "-c", "core.quotepath=false"]
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
        // Stable English diagnostics: every failure classifier (PullError,
        // SyncManager.deterministicPushRejection, blockedUntrackedFiles, …)
        // matches English phrases. A gettext-enabled git under a Chinese locale
        // prints translated messages, which silently degraded every failure to
        // "unknown" (no auto-rebase, no branch-protection stop).
        //
        // v4.2.26: FORCE this instead of only defaulting it. Inheriting the
        // user's LANG/LC_ALL (Terminal launch, `launchctl setenv`, login item)
        // reintroduced exactly the bug v4.2.25 fixed. Callers can still opt out
        // with an explicit `env:` override below.
        e["LC_ALL"] = "C"
        e["LANG"] = "C"
        // FileVault is headless: no git command may ever open an editor or a
        // pager and block the command (and the caller's timeout) on stdin.
        if e["GIT_EDITOR"] == nil { e["GIT_EDITOR"] = "true" }
        if e["GIT_PAGER"] == nil { e["GIT_PAGER"] = "cat" }
        // GIT_TERMINAL_PROMPT=0 only blocks the TERMINAL prompt; a configured
        // core.askpass (or inherited GIT_ASKPASS) still pops a GUI box in the
        // background and blocks until the command timeout (v4.2.27). Provide an
        // empty-answer askpass unless the user explicitly set one.
        if e["GIT_ASKPASS"] == nil { e["GIT_ASKPASS"] = "/usr/bin/true" }
        if e["SSH_ASKPASS"] == nil { e["SSH_ASKPASS"] = "/usr/bin/true" }
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

        // stdin is fed AFTER the child is spawned: writing a large payload into
        // the pipe before `run()` blocks forever once the 64 KB pipe buffer is
        // full (no reader exists yet). The write also runs off this thread so a
        // slow consumer can never block the caller (v4.2.25).
        var stdinPipe: Pipe?
        if stdin != nil {
            let inPipe = Pipe()
            process.standardInput = inPipe
            stdinPipe = inPipe
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
            // No child will ever read stdin: close it so a queued writer wakes
            // with EPIPE instead of blocking a global-queue thread forever.
            stdinPipe?.fileHandleForWriting.closeFile()
            throw error
        }

        if let stdin, let inPipe = stdinPipe {
            let payload = Data(stdin.utf8)
            DispatchQueue.global().async {
                do {
                    try inPipe.fileHandleForWriting.write(contentsOf: payload)
                } catch {
                    // EPIPE: the command exited without reading its input. Not
                    // fatal; the exit status and stderr explain the failure.
                }
                try? inPipe.fileHandleForWriting.close()
            }
        }

        let exitSem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSem.signal() }

        let waitResult = exitSem.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            // Kill git's direct children (ssh, git-remote-https, credential
            // helpers) BEFORE git itself: they inherit the stdout/stderr pipe
            // write ends, so a surviving child keeps the reader threads below
            // blocked on EOF even after git is gone. That leaked one
            // global-queue thread per timed-out fetch/push (v4.2.26). Best
            // effort: a missing pkill or an already-dead child is ignored.
            Self.terminateChildProcesses(of: process.processIdentifier)
            process.terminate()
            if exitSem.wait(timeout: .now() + 5) == .timedOut {
                // SIGTERM was ignored (or the process is stuck in an
                // uninterruptible syscall on a dying network mount): force it,
                // otherwise every timed-out push leaks a child plus its readers.
                kill(process.processIdentifier, SIGKILL)
                _ = exitSem.wait(timeout: .now() + 2)
            }
            // Release the pipe readers even if a descendant still holds the
            // write ends; a leaked reader would block a global-queue thread.
            outPipe.fileHandleForWriting.closeFile()
            errPipe.fileHandleForWriting.closeFile()
            stdinPipe?.fileHandleForWriting.closeFile()
            _ = group.wait(timeout: .now() + 5)
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
    /// Send SIGTERM to the direct children of `pid` (`pkill -TERM -P`).
    ///
    /// A timed-out git leaves ssh / git-remote-* descendants holding the
    /// stdout/stderr pipes; without this the pipe readers stay blocked long
    /// after the main process is killed. Failure is non-fatal: the timeout
    /// path below still SIGTERMs/SIGKILLs the main process.
    private static func terminateChildProcesses(of pid: pid_t) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(pid)]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        do {
            try pkill.run()
        } catch {
            return
        }
        pkill.waitUntilExit()
    }

    /// One-time `gh auth setup-git` so GitHub HTTPS pushes work without manual
    /// credential setup (idempotent).
    public static func ghAuthSetupGit() async {
        // ghURL()'s "/usr/bin/env" fallback is always executable, so an
        // executability check alone ran `/usr/bin/env auth setup-git` (exit 127)
        // on every Mac without gh (v4.2.28). Require a real gh binary.
        let gh = SelfUpdater.ghURL()
        guard gh.lastPathComponent == "gh", FileManager.default.isExecutableFile(atPath: gh.path) else {
            return
        }
        let p = Process()
        p.executableURL = gh
        p.arguments = ["auth", "setup-git"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

}