
import XCTest
@testable import FileVaultCore

/// v4.2.32 watchlist item 10: the strategy-3 (Xcode CLT) fallback path was
/// untestable — running the real xcode-select pops a modal ~1.5 GB system
/// dialog. The injected xcodeCLTTrigger seam pins the ladder end-to-end:
/// mirrors fail → CLT triggered → a git that appeared meanwhile is adopted;
/// and the all-fail refusal.
final class GitEnvCLTFallbackTests: XCTestCase {

    /// Stateful locator: nil until the "CLT install" completes, then a
    /// working fake git (mirrors a user installing the tools while the
    /// dialog was up).
    private final class LocatingAfterCLT: GitLocator, @unchecked Sendable {
        private let lock = NSLock()
        private var installed = false
        let gitPath: String
        init(gitPath: String) { self.gitPath = gitPath }
        func markInstalled() {
            lock.lock(); installed = true; lock.unlock()
        }
        func locate() -> String? {
            lock.lock(); defer { lock.unlock() }
            return installed ? gitPath : nil
        }
    }

    private final class FailingProvisioner: GitProvisioning, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
        func provision(progress: GitProvisionProgress?) async throws -> String {
            // The lock work runs synchronously off the async context.
            Self.bump(self)
            throw GitProvisionError.noMirrors
        }
        private static func bump(_ p: FailingProvisioner) {
            p.lock.lock(); p.calls += 1; p.lock.unlock()
        }
    }

    /// Thread-safe counter for the CLT trigger callback (a @Sendable closure
    /// cannot capture a plain var under strict checking).
    private final class TriggerCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// A fake git that answers --version (GitEnvGuard executes it).
    private func makeFakeGit(_ dir: String) throws -> String {
        let git = dir + "/fake-git"
        let script = """
        #!/bin/sh
        echo "git version 9.9.9-test"
        """
        try script.write(toFile: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git)
        return git
    }

    func testInstallFallsThroughMirrorsToCLTAndAdoptsNewlyAvailableGit() async throws {
        let base = TestSupport.makeTempDir("ge-clt")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let git = try makeFakeGit(base)
        let locator = LocatingAfterCLT(gitPath: git)
        let provisioner = FailingProvisioner()
        let guard_ = GitEnvGuard(locator: locator, provisioner: provisioner,
                                 allowXcodeCLTFallback: true)
        let triggers = TriggerCounter()
        guard_.xcodeCLTTrigger = { triggers.increment(); locator.markInstalled() }

        let detection = try await guard_.install()
        XCTAssertEqual(detection.gitPath, git, "a git that appears during the CLT dialog is adopted")
        XCTAssertEqual(detection.version, "9.9.9-test")
        XCTAssertEqual(provisioner.callCount, 1, "the mirror ladder ran before strategy 3")
        XCTAssertEqual(triggers.value, 1, "the CLT fallback fires exactly once")
        XCTAssertEqual(guard_.lastStrategy, .xcodeCLT)
        if case .ready = guard_.status {} else { XCTFail("status must be ready") }
    }

    func testInstallAllFailSurfacesProvisionFailureAfterCLTAttempt() async throws {
        let base = TestSupport.makeTempDir("ge-clt-fail")
        defer { try? FileManager.default.removeItem(atPath: base) }
        // Locator never finds anything.
        final class NeverLocator: GitLocator, @unchecked Sendable {
            func locate() -> String? { nil }
        }
        let guard_ = GitEnvGuard(locator: NeverLocator(),
                                 provisioner: FailingProvisioner(),
                                 allowXcodeCLTFallback: true)
        let triggers = TriggerCounter()
        guard_.xcodeCLTTrigger = { triggers.increment() }

        do {
            _ = try await guard_.install()
            XCTFail("everything failing must throw")
        } catch {
            guard case GitEnvError.provisionFailed = error else {
                return XCTFail("expected provisionFailed, got \(error)")
            }
        }
        XCTAssertEqual(triggers.value, 1, "the CLT dialog was triggered before giving up")
        XCTAssertEqual(guard_.lastStrategy, .xcodeCLT)
    }

    /// With the fallback disabled (tests, production never), the trigger must
    /// never fire and the download failure surfaces directly.
    func testInstallWithoutCLTFallbackSkipsTrigger() async throws {
        final class NeverLocator: GitLocator, @unchecked Sendable {
            func locate() -> String? { nil }
        }
        let guard_ = GitEnvGuard(locator: NeverLocator(),
                                 provisioner: FailingProvisioner(),
                                 allowXcodeCLTFallback: false)
        let triggers = TriggerCounter()
        guard_.xcodeCLTTrigger = { triggers.increment() }
        do {
            _ = try await guard_.install()
            XCTFail("must throw when the ladder is exhausted")
        } catch {
            guard case GitEnvError.provisionFailed = error else {
                return XCTFail("expected provisionFailed, got \(error)")
            }
        }
        XCTAssertEqual(triggers.value, 0, "allowXcodeCLTFallback=false must skip strategy 3")
    }
}
