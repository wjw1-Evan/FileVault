import Foundation

/// Creates a private GitHub repo and returns its HTTPS clone URL (P2 gh integration).
public struct GhRepoCreator {
    public init() {}

    /// The one naming rule for a GitHub repository (v4.2.32): used by
    /// createPrivate here and by the create-repo dialog, so validation and
    /// execution can never disagree.
    public static func isValidRepoName(_ raw: String) -> Bool {
        let safe = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !safe.isEmpty
            && safe.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    /// Returns the clone URL, e.g. https://github.com/user/name.git
    ///
    /// `createTimeout` is the budget for the repo-create call itself
    /// (injectable so tests can exercise the timeout branch quickly;
    /// production keeps the 60 s default, v4.2.32).
    public func createPrivate(name: String, ghPath: String = GhRepoCreator.defaultGhPath(),
                              createTimeout: TimeInterval = 60) async throws -> String {
        let safe = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Single source of truth for the naming rule (v4.2.32): the create-repo
        // sheet validated with its own copy of this regex, so the two could
        // drift into "dialog accepts, gh rejects".
        guard Self.isValidRepoName(safe) else {
            throw GitCommandError(command: "repo create", exitCode: -1,
                                  stderr: NSLocalizedString("仓库名只能包含字母、数字、点、下划线和连字符", comment: "gh repo error"))
        }
        let createResult = try await runGh(ghPath, ["repo", "create", safe, "--private"], timeout: createTimeout)
        guard createResult.succeeded else {
            throw GitCommandError(command: "repo create", exitCode: createResult.exitCode, stderr: createResult.stderr)
        }
        // Resolve the account login; a failure/empty login previously produced
        // a garbage "https://github.com//<name>.git" URL (v2.6.6 audit).
        let whoResult = try await runGh(ghPath, ["api", "user", "--jq", ".login"], timeout: 20)
        let login = whoResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard whoResult.succeeded, !login.isEmpty, !login.contains(" ") else {
            throw GitCommandError(command: "api user", exitCode: whoResult.exitCode,
                                  stderr: whoResult.stderr.isEmpty
                                      ? NSLocalizedString("无法获取 gh 账号名（gh 未登录？）", comment: "gh repo error")
                                      : whoResult.stderr)
        }
        return "https://github.com/" + login + "/" + safe + ".git"
    }

    /// Run one gh invocation with a bounded wait — an unresponsive network used
    /// to block the creation Task forever (v2.6.6 audit).
    ///
    /// The blocking semaphore wait no longer sits on a Swift cooperative-pool
    /// thread (a Swift 6 error, and a real starvation hazard: the pool is
    /// tiny and shared with every async job, v4.2.31). The whole run-and-wait
    /// lives in a synchronous helper on the global dispatch queue, bridged
    /// back with a continuation.
    private func runGh(_ ghPath: String, _ args: [String], timeout: TimeInterval) async throws -> GitResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GitResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try Self.runGhBlocking(ghPath, args, timeout: timeout) })
            }
        }
    }

    private static func runGhBlocking(_ ghPath: String, _ args: [String],
                                      timeout: TimeInterval) throws -> GitResult {
        guard !ghPath.isEmpty, ghPath != "/usr/bin/env",
              FileManager.default.isExecutableFile(atPath: ghPath) else {
            throw GitCommandError(command: args.joined(separator: " "), exitCode: -1,
                                  stderr: NSLocalizedString("gh 不可用（请安装 GitHub CLI）", comment: "gh repo error"))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ghPath)
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        // Readers must be draining BEFORE the child is spawned (v4.2.32): the
        // old wait-then-read design deadlocked once gh wrote more than the
        // 64 KB pipe buffer — the blocked write kept the process from ever
        // exiting, and the whole call died on the timeout. Same shape as
        // GitRunner.runSync.
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
        do {
            try p.run()
        } catch {
            // The readers above are already waiting for EOF: without the
            // write ends being closed they would block forever (GitRunner's
            // spawn-failure lesson).
            outPipe.fileHandleForWriting.closeFile()
            errPipe.fileHandleForWriting.closeFile()
            throw GitCommandError(command: args.joined(separator: " "), exitCode: -1,
                                  stderr: NSLocalizedString("gh 不可用（请安装 GitHub CLI）", comment: "gh repo error"))
        }
        // Bounded wait: terminate → force-kill on timeout instead of hanging forever.
        let exitSem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exitSem.signal() }
        if exitSem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exitSem.wait(timeout: .now() + 5) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exitSem.wait(timeout: .now() + 2)
            }
            // Release the pipe readers (a descendant holding the write ends
            // would otherwise block them even after gh is gone).
            outPipe.fileHandleForWriting.closeFile()
            errPipe.fileHandleForWriting.closeFile()
            _ = group.wait(timeout: .now() + 5)
            throw GitCommandError(command: args.joined(separator: " "), exitCode: -9,
                                  stderr: String(format: NSLocalizedString("gh 命令超时（%ds）", comment: "gh repo error"),
                                                 Int(timeout)))
        }
        p.terminationHandler = nil
        // Defense in depth (GitRunner's rule): normally EOF arrives with the
        // exit; if some fd-holding descendant keeps a pipe open, proceed with
        // what was captured instead of deadlocking the reader threads.
        if group.wait(timeout: .now() + 10) == .timedOut {
            outPipe.fileHandleForWriting.closeFile()
            errPipe.fileHandleForWriting.closeFile()
            _ = group.wait(timeout: .now() + 2)
        }
        return GitResult(exitCode: p.terminationStatus,
                          stdout: String(decoding: outData, as: UTF8.self),
                          stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Absolute path of an installed gh, or "" when there is none.
    ///
    /// The old fallback returned "/usr/bin/env", which is always executable, so
    /// the "gh 不可用（请安装 GitHub CLI）" guard never fired and the user got
    /// "env: repo: No such file or directory" with exit code 127 instead
    /// (v4.2.25).
    public static func defaultGhPath() -> String {
        for p in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        for p in ["/usr/bin/gh", "/opt/local/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return ""
    }
}
