import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// v4.2.32 closure audit: after a successful restore the footer's success
/// CTA must reveal THE recovered file. The list selection moves on to the
/// next file right after a restore, so the plain reveal button would show
/// a different file — the pending path is what keeps the CTA honest.
@MainActor
final class RecoverySuccessCTATests: XCTestCase {

    @MainActor
    private func makeModel() async throws -> (RecoveryModel, FileVaultService, String) {
        let base = TestSupport.makeTempDir("recover-cta")
        let vault = base + "/vault"
        try? FileManager.default.createDirectory(atPath: vault + "/笔记", withIntermediateDirectories: true)
        TestSupport.write("会议内容 v1", to: vault + "/笔记/会议记录.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: vault)
        let model = RecoveryModel()
        model.bind(AppState(service: service))
        return (model, service, base)
    }

    @MainActor
    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// The core value moment: 找回成功 must keep the recovered path for the
    /// footer's CTA — and it must SURVIVE the post-restore selection move.
    func testRestoreSuccessKeepsRecoveredPathForTheCTA() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/vault"
        let file = "笔记/会议记录.md"
        await waitFor("initial scan") { model.snapshot != nil }

        try FileManager.default.removeItem(atPath: repo + "/" + file)
        _ = try await service.repoManager.commitAll(path: repo, message: "删除会议记录")
        model.reload(preserveSelection: false)
        await waitFor("deleted file listed") { model.deletedCount == 1 }
        model.setScope(.deleted)
        await waitFor("versions loaded") { !model.versions.isEmpty && model.selectedVersion != nil }

        XCTAssertNil(model.restoredPathForReveal, "nothing restored yet")
        model.restore()
        await waitFor("file recovered") {
            FileManager.default.fileExists(atPath: repo + "/" + file) && model.deletedCount == 0
        }
        XCTAssertEqual(model.restoredPathForReveal, file,
                       "the success CTA must point at the file that just came back")
        XCTAssertTrue(model.statusText.contains("已找回"), "feedback: \(model.statusText)")
    }

    /// A folder switch invalidates the pending CTA: its relative path
    /// belongs to the PREVIOUS folder.
    func testFolderSwitchClearsThePendingRevealCTA() async throws {
        let (model, _, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        await waitFor("initial scan") { model.snapshot != nil }

        model.restoredPathForReveal = "笔记/会议记录.md"
        model.rootChanged(base + "/somewhere-else")
        XCTAssertNil(model.restoredPathForReveal,
                     "switching folders must drop the previous folder's pending CTA")
    }
}
