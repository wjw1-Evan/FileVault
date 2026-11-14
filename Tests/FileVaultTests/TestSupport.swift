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
}
