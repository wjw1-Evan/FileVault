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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ghPath)
        p.arguments = ["repo", "create", safe, "--private"]
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            throw GitCommandError(command: "repo create", exitCode: -1, stderr: "gh 不可用")
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw GitCommandError(command: "repo create", exitCode: p.terminationStatus, stderr: err)
        }
        let who = Process()
        who.executableURL = URL(fileURLWithPath: ghPath)
        who.arguments = ["api", "user", "--jq", ".login"]
        let outPipe = Pipe()
        who.standardOutput = outPipe
        who.standardError = FileHandle.nullDevice
        try? who.run()
        who.waitUntilExit()
        let login = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "https://github.com/" + login + "/" + safe + ".git"
    }

    public static func defaultGhPath() -> String {
        for p in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/usr/bin/env"
    }
}
