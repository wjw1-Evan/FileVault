import XCTest
@testable import FileVaultCore

/// The v2.6.6 empty-login guard: 'gh repo create' succeeding while
/// 'gh api user' resolves no login used to produce the garbage URL
/// https://github.com//name.git — an unreadable failure far from the cause.
final class GhRepoCreatorResolveLoginTests: XCTestCase {

    private func makeFakeGh(loginOutput: String?) throws -> String {
        let base = TestSupport.makeTempDir("ghlogin")
        let path = base + "/gh"
        var body = "#!/bin/sh\n"
        if let loginOutput {
            body += "if [ \"$1\" = \"api\" ]; then printf '" + loginOutput + "'; exit 0; fi\n"
        }
        body += "exit 0\n"
        TestSupport.write(body, to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testEmptyLoginIsRefusedWithReadableError() async throws {
        let gh = try makeFakeGh(loginOutput: "\n")
        do {
            _ = try await GhRepoCreator().createPrivate(name: "my-notes", ghPath: gh)
            XCTFail("an empty login must not produce a garbage URL")
        } catch let error as GitCommandError {
            XCTAssertTrue(error.stderr.contains("无法获取 gh 账号名"), error.stderr)
        }
    }

    func testLoginWithSpacesIsRefused() async throws {
        // A multi-word stdout (a wrapped error banner, not a login) must be
        // refused by the same guard.
        let gh = try makeFakeGh(loginOutput: "two words\n")
        do {
            _ = try await GhRepoCreator().createPrivate(name: "my-notes", ghPath: gh)
            XCTFail("a space-bearing login must not produce a garbage URL")
        } catch let error as GitCommandError {
            XCTAssertTrue(error.stderr.contains("无法获取 gh 账号名"), error.stderr)
        }
    }
}
