import AppKit
import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// v4.1 recovery window: the model lists deleted/modified files, loads one
/// file's versions automatically, and restores through the same core service
/// as the history window.
final class RecoveryModelTests: XCTestCase {
    @MainActor
    private func makeModel() async throws -> (RecoveryModel, FileVaultService, String) {
        let base = TestSupport.makeTempDir("recovery-model")
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

    @MainActor
    func testDeletedFileIsListedAndItsVersionsAutoLoad() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/vault"
        let file = "笔记/会议记录.md"
        await waitFor("initial scan") { model.snapshot != nil && model.allCount > 0 }

        try FileManager.default.removeItem(atPath: repo + "/" + file)
        _ = try await service.repoManager.commitAll(path: repo, message: "删除会议记录")
        model.reload(preserveSelection: false)
        await waitFor("deleted file listed") { model.deletedCount == 1 }
        // The first scan auto-picks a scope; a deleted file must be one click away.
        model.setScope(.deleted)
        await waitFor("deleted scope selected") { model.selectedPath == file }

        XCTAssertEqual(model.visibleFiles.map(\.path), [file])
        XCTAssertEqual(model.selectedPath, file)
        await waitFor("versions loaded") { !model.versions.isEmpty }
        XCTAssertTrue(model.versions.contains { $0.isDeletion })
        XCTAssertTrue(model.versions.contains { $0.exists })
        XCTAssertNotNil(model.recommendedVersion)
        XCTAssertEqual(model.selectedVersionHash, model.recommendedVersion?.hash)
        await waitFor("preview loaded") { model.preview == .text("会议内容 v1") }
        XCTAssertTrue(model.canRestore)
    }

    @MainActor
    func testRestoreFromModelRecoversTheFileAndLeavesTheList() async throws {
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

        model.restore()
        await waitFor("file recovered") {
            FileManager.default.fileExists(atPath: repo + "/" + file) && model.deletedCount == 0
        }
        let recovered = try String(contentsOfFile: repo + "/" + file, encoding: .utf8)
        XCTAssertEqual(recovered, "会议内容 v1")
        XCTAssertTrue(model.statusText.contains("已找回"), "feedback: \(model.statusText)")
        let top = try await service.repoManager.log(path: repo).first
        XCTAssertTrue(top?.subject.contains("restore") == true, "commit: \(top?.subject ?? "nil")")
    }

    @MainActor
    func testScopeSwitchFiltersDeletedAndModifiedFiles() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/vault"
        await waitFor("initial scan") { model.snapshot != nil }
        await service.setRootPaused(true, root: repo)

        try FileManager.default.removeItem(atPath: repo + "/笔记/会议记录.md")
        TestSupport.write("改坏的内容", to: repo + "/笔记/草稿.md")
        _ = try await service.repoManager.commitAll(path: repo, message: "删除会议记录并加草稿")
        TestSupport.write("又改了一次", to: repo + "/笔记/草稿.md")

        model.reload(preserveSelection: false)
        await waitFor("both scopes populated") { model.deletedCount == 1 && model.modifiedCount == 1 }

        model.setScope(.deleted)
        XCTAssertEqual(model.visibleFiles.map(\.path), ["笔记/会议记录.md"])
        model.setScope(.recent)
        let recent = model.visibleFiles.map(\.path)
        XCTAssertTrue(recent.contains("笔记/草稿.md"), "\(recent)")
        XCTAssertTrue(recent.contains("笔记/会议记录.md"),
                      "a just-deleted file is also a recent change: \(recent)")
        model.setScope(.all)
        XCTAssertTrue(model.visibleFiles.contains { $0.path == "笔记/会议记录.md" })
        XCTAssertTrue(model.visibleFiles.contains { $0.path == "笔记/草稿.md" })
        await service.setRootPaused(false, root: repo)
    }

    @MainActor
    func testSearchFiltersByPath() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/vault"
        await waitFor("initial scan") { model.snapshot != nil }
        TestSupport.write("x", to: repo + "/笔记/另一份.md")
        _ = try await service.repoManager.commitAll(path: repo, message: "another")
        model.reload(preserveSelection: false)
        await waitFor("two files indexed") { model.allCount >= 2 }

        model.setScope(.all)
        model.searchText = "会议"
        XCTAssertTrue(model.visibleFiles.allSatisfy { $0.path.contains("会议") })
        XCTAssertFalse(model.visibleFiles.isEmpty)

        model.searchText = "不存在的文件"
        XCTAssertTrue(model.visibleFiles.isEmpty)
    }

    @MainActor
    func testRestorePromptExplainsWhatWillHappen() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/vault"
        await waitFor("initial scan") { model.snapshot != nil }
        try FileManager.default.removeItem(atPath: repo + "/笔记/会议记录.md")
        _ = try await service.repoManager.commitAll(path: repo, message: "删除")
        model.reload(preserveSelection: false)
        await waitFor("deleted file listed") { model.deletedCount == 1 }
        model.setScope(.deleted)
        await waitFor("deleted file selected") { model.selectedPath != nil && model.selectedVersion != nil }

        XCTAssertTrue(model.restorePrompt.contains("恢复到文件夹中"), model.restorePrompt)
        XCTAssertTrue(model.restorePrompt.contains("会议记录.md"), model.restorePrompt)
    }
}
