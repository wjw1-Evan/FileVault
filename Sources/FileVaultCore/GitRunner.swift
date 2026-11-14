import Foundation

/// Result of one git command execution.
public struct GitResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }
}

/// Error thrown when a git command fails.
public struct GitCommandError: Error, Sendable {
    public let command: String
    public let exitCode: Int32
    public let stderr: String

    public var errorDescription: String {
        "git \(command) failed (exit \(exitCode)): \(stderr)"
    }
}

/// Thin wrapper that executes git via `Process` with timeout and output capture.
public final class GitRunner: Sendable {
    public let gitExecutable: String
    public let defaultTimeout: TimeInterval

    public init(gitExecutable: String, defaultTimeout: TimeInterval = 30) {
        self.gitExecutable = gitExecutable
        self.defaultTimeout = defaultTimeout
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
        process.arguments = args

        var e = ProcessInfo.processInfo.environment
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

        try process.run()

        let exitSem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSem.signal() }

        let waitResult = exitSem.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            process.terminate()
            _ = exitSem.wait(timeout: .now() + 5)
            throw GitCommandError(command: args.joined(separator: " "), exitCode: -9, stderr: "git command timed out after \(timeout)s")
        }

        group.wait()
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