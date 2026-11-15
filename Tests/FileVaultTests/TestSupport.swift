import Foundation
import XCTest
@testable import FileVaultCore

/// Shared helpers for tests.
enum TestSupport {
    static func makeTempDir(_ name: String) -> String {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("fv-tests-\(name)-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }

    static func gitPath() -> String {
        "/usr/bin/git"
    }

    static func newRunner() -> GitRunner {
        GitRunner(gitExecutable: gitPath())
    }

    @discardableResult
    static func write(_ content: String, to path: String) -> Bool {
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        return FileManager.default.fileExists(atPath: path)
    }

    /// Create a sparse file with the given logical size (no disk cost, instant).
    @discardableResult
    static func writeSparse(_ path: String, bytes: UInt64) -> Bool {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        do {
            try handle.truncate(atOffset: bytes)
        } catch {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }
}
