import XCTest
@testable import FileVaultCore

/// Fake locator for install-strategy tests.
final class FakeLocator: GitLocator {
    let result: String?
    init(result: String?) { self.result = result }
    func locate() -> String? { result }
}

final class GitEnvGuardTests: XCTestCase {
    func testDetectWithRealGit() async {
        let guard_ = GitEnvGuard(locator: FakeLocator(result: "/usr/bin/git"))
        let r = await guard_.detect()
        guard case .success(let d) = r else {
            return XCTFail("detect should succeed with real git")
        }
        XCTAssertEqual(d.gitPath, "/usr/bin/git")
        XCTAssertTrue(d.version.contains("2."))
        XCTAssertEqual(d.source, .system)
    }

    func testDetectFailsWithoutGit() async {
        let guard_ = GitEnvGuard(locator: FakeLocator(result: nil))
        let r = await guard_.detect()
        guard case .failure = r else {
            return XCTFail("detect should fail without git")
        }
        if case .failed = guard_.status {} else { XCTFail("status should be failed") }
    }

    func testVersionParsing() {
        let v = GitEnvGuard.version(fromExecutable: "/usr/bin/git")
        XCTAssertNotNil(v)
        XCTAssertTrue(v?.contains("2.") ?? false)
    }
}
