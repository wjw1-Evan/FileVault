import Foundation

/// Creates a private GitHub repo and returns its HTTPS clone URL (P2 gh integration).
public struct GhRepoCreator {
    public init() {}

    /// Returns the clone URL, e.g. https://github.com/user/name.git
    public func createPrivate(name: String, ghPath: String = GhRepoCreator.defaultGhPath()) async throws -> String {
        let safe = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty,
              safe.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw GitCommandError(command: "repo create", exitCode: -1,
                                  stderr: "仓库名只能包含字母、数字、点、下划线和连字符")
        }
        let createResult = try await runGh(ghPath, ["repo", "create", safe, "--private"], timeout: 60)
        guard createResult.succeeded else {
            throw GitCommandError(command: "repo create", exitCode: createResult.exitCode, stderr: createResult.stderr)
        }
        // Resolve the account login; a failure/empty login previously produced
        // a garbage "https://github.com//<name>.git" URL (v2.6.6 audit).
        let whoResult = try await runGh(ghPath, ["api", "user", "--jq", ".login"], timeout: 20)
        let login = whoResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard whoResult.succeeded, !login.isEmpty, !login.contains(" ") else {
            throw GitCommandError(command: "api user", exitCode: whoResult.exitCode,
                                  stderr: whoResult.stderr.isEmpty ? "无法获取 gh 账号名（gh 未登录？）" : whoResult.stderr)
        }
        return "https://github.com/" + login + "/" + safe + ".git"
    }

    /// Run one gh invocation with a bounded wait — an unresponsive network used
    /// to block the creation Task forever (v2.6.6 audit).
    private func runGh(_ ghPath: String, _ args: [String], timeout: TimeInterval) async throws -> GitResult {
        guard FileManager.default.isExecutableFile(atPath: ghPath) else {
            throw GitCommandError(command: args.joined(separator: " "), exitCode: -1, stderr: "gh 不可用（请安装 GitHub CLI）")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ghPath)
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            throw GitCommandError(command: args.joined(separator: " "), exitCode: -1, stderr: "gh 不可用（请安装 GitHub CLI）")
        }
        // Bounded wait: terminate on timeout instead of hanging forever.
        let exitSem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exitSem.signal() }
        if exitSem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = exitSem.wait(timeout: .now() + 5)
            throw GitCommandError(command: args.joined(separator: " "), exitCode: -9,
                                  stderr: "gh 命令超时（\(Int(timeout))s）")
        }
        p.terminationHandler = nil
        // Read AFTER exit (process-owned fds are closed; both buffers are complete).
        let stdout = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return GitResult(exitCode: p.terminationStatus, stdout: stdout, stderr: stderr)
    }

    public static func defaultGhPath() -> String {
        for p in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/usr/bin/env"
    }
}
