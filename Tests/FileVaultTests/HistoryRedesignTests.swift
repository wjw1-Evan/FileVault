import AppKit
import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// v4.0.1 history window redesign: pure grouping/classification helpers plus
/// the preview pipeline driven by HistoryModel.
final class HistoryTimelineTests: XCTestCase {
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: c)!
    }

    func testGroupsCommitsByDayKeepingNewestFirst() {
        let now = date(2026, 11, 15, 22, 30)
        let commits = [
            CommitInfo(hash: "a1", shortHash: "a1", subject: "today late", date: date(2026, 11, 15, 22, 10)),
            CommitInfo(hash: "a2", shortHash: "a2", subject: "today early", date: date(2026, 11, 15, 8, 5)),
            CommitInfo(hash: "b1", shortHash: "b1", subject: "yesterday", date: date(2026, 11, 14, 23, 18)),
            CommitInfo(hash: "c1", shortHash: "c1", subject: "older", date: date(2026, 11, 12, 10, 41)),
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let sections = HistoryTimeline.sections(for: commits, now: now, calendar: calendar,
                                                locale: Locale(identifier: "zh_CN"))

        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].title, "今天")
        XCTAssertEqual(sections[0].commits.map(\.subject), ["today late", "today early"])
        XCTAssertEqual(sections[1].title, "昨天")
        XCTAssertEqual(sections[1].commits.map(\.subject), ["yesterday"])
        XCTAssertEqual(sections[2].commits.map(\.subject), ["older"])
        // Distinct stable ids per day.
        XCTAssertEqual(Set(sections.map(\.id)).count, 3)
    }

    func testEmptyInputYieldsNoSections() {
        XCTAssertTrue(HistoryTimeline.sections(for: []).isEmpty)
    }
}

final class HistoryPreviewKindTests: XCTestCase {
    func testTextExtensionsArePreviewedInline() {
        for path in ["a.md", "笔记/会议记录.markdown", "README", "b.txt", "c.json", "d.swift"] {
            XCTAssertEqual(HistoryPreviewKind.classify(path: path), .text, path)
        }
    }

    func testImageExtensionsArePreviewedInline() {
        for path in ["cover.png", "设计/封面.PNG", "photo.JPG", "a.jpeg", "anim.gif",
                     "shot.heic", "pic.webp", "scan.tiff", "icon.icns"] {
            XCTAssertEqual(HistoryPreviewKind.classify(path: path), .image, path)
        }
    }

    func testBinaryExtensionsAreNotInlined() {
        for path in ["scan.pdf", "archive.zip", "doc.docx", "movie.mp4"] {
            XCTAssertEqual(HistoryPreviewKind.classify(path: path), .binary, path)
        }
    }

    func testImagePreviewLimitIsReasonable() {
        XCTAssertGreaterThanOrEqual(HistoryPreviewKind.imagePreviewLimit, 4 * 1024 * 1024)
        XCTAssertLessThanOrEqual(HistoryPreviewKind.imagePreviewLimit, 64 * 1024 * 1024)
    }

    func testTextPreviewLimitIsReasonable() {
        XCTAssertGreaterThanOrEqual(HistoryPreviewKind.textPreviewLimit, 64 * 1024)
        XCTAssertLessThanOrEqual(HistoryPreviewKind.textPreviewLimit, 2 * 1024 * 1024)
    }
}

final class HistoryPreviewModelTests: XCTestCase {
    @MainActor
    func testSelectingAFileLoadsItsTextPreviewAndAutoSelectsFirst() async throws {
        let base = TestSupport.makeTempDir("hist-preview")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let vault = base + "/vault"
        try? FileManager.default.createDirectory(atPath: vault + "/笔记", withIntermediateDirectories: true)
        TestSupport.write("会议内容 v1", to: vault + "/笔记/会议记录.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: vault)

        let model = HistoryModel()
        model.bind(AppState(service: service))
        for _ in 0..<60 where model.files.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(model.commits.isEmpty)
        XCTAssertFalse(model.files.isEmpty)
        XCTAssertNotNil(model.selectedFile, "a file is auto-selected for preview")
        // The initial commit also contains the injected .gitignore, so pick the
        // content file explicitly to assert the text preview.
        model.selectFile("笔记/会议记录.md")
        for _ in 0..<60 where model.preview != .text("会议内容 v1") {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.preview, .text("会议内容 v1"))

        model.selectFile(nil)
        XCTAssertNil(model.selectedFile)
        XCTAssertEqual(model.preview, .none)
    }

    /// Images are decoded and shown inline; the raw blob must be exact.
    @MainActor
    func testSelectingAnImageLoadsInlinePreview() async throws {
        let base = TestSupport.makeTempDir("hist-image")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let vault = base + "/vault"
        try? FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        try png.write(to: URL(fileURLWithPath: vault + "/pic.png"))
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: vault)

        let model = HistoryModel()
        model.bind(AppState(service: service))
        for _ in 0..<60 where model.files.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        model.selectFile("pic.png")
        for _ in 0..<60 {
            if case .image = model.preview { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard case .image(let data) = model.preview else {
            XCTFail("expected inline image preview, got \(model.preview)")
            return
        }
        XCTAssertEqual(data, png, "the exact blob must be handed to the preview")
        XCTAssertNotNil(NSImage(data: data), "AppKit can decode the previewed bytes")
    }
}

final class HistoryFileSizeTests: XCTestCase {
    func testFileSizeMatchesBlobAndRejectsMissingFile() async throws {
        let base = TestSupport.makeTempDir("hist-size")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/repo"
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repo)
        let bytes = Data(repeating: 0x41, count: 1234)
        try bytes.write(to: URL(fileURLWithPath: repo + "/blob.bin"))
        _ = try await repos.commitAll(path: repo)
        let commits = try await repos.log(path: repo)
        let hash = try XCTUnwrap(commits.first?.hash)
        let history = HistoryService(repoManager: repos)

        let size = try await history.fileSize(repoPath: repo, hash: hash, file: "blob.bin")
        XCTAssertEqual(size, 1234)
        do {
            _ = try await history.fileSize(repoPath: repo, hash: hash, file: "missing.bin")
            XCTFail("missing file must throw")
        } catch {
            XCTAssertTrue(error is HistoryError, "got \(error)")
        }
    }
}


    func testFileDataReturnsExactBinaryBlob() async throws {
        let base = TestSupport.makeTempDir("hist-data")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/repo"
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repo)
        // Not valid UTF-8: must still round-trip byte-for-byte.
        let bytes = Data((0..<768).map { UInt8(($0 * 37) % 256) })
        try bytes.write(to: URL(fileURLWithPath: repo + "/blob.bin"))
        _ = try await repos.commitAll(path: repo)
        let commits = try await repos.log(path: repo)
        let hash = try XCTUnwrap(commits.first?.hash)
        let history = HistoryService(repoManager: repos)

        let got = try await history.fileData(repoPath: repo, hash: hash, file: "blob.bin")
        XCTAssertEqual(got, bytes)
        do {
            _ = try await history.fileData(repoPath: repo, hash: hash, file: "missing.bin")
            XCTFail("missing file must throw")
        } catch {
            XCTAssertTrue(error is HistoryError, "got \(error)")
        }
    }

final class ConfigDirectoryOverrideTests: XCTestCase {
    func testFVConfigDirOverridesDefaultDirectory() {
        let previous = ProcessInfo.processInfo.environment["FV_CONFIG_DIR"]
        setenv("FV_CONFIG_DIR", "/private/tmp/fv-config-override-test", 1)
        defer {
            if let previous { setenv("FV_CONFIG_DIR", previous, 1) } else { unsetenv("FV_CONFIG_DIR") }
        }
        XCTAssertEqual(ConfigStore.defaultDirectory.path, "/private/tmp/fv-config-override-test")
    }
}
