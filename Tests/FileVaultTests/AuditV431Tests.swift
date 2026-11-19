import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// v4.2.31: regression cover for the interaction bugs found while reviewing
/// the v4.2.30 round (drop onto an already-open add sheet, double-add while a
/// repo creation is in flight, valid ssh:// remotes rejected by the address
/// guard) and direct tests for the pure logic that shipped without any.
final class AuditV431Tests: XCTestCase {

    // MARK: - Onboarding contract (v4.2.30 flag change, v4.2.31 pinned)

    /// The flag must flip when the first folder is PROTECTED — not when the
    /// first-run sheet is shown. The old placement meant one 取消 silenced
    /// the welcome forever with no visible next step left anywhere.
    @MainActor
    func testOnboardingFlagIsSetOnlyOnceAFolderIsProtected() async throws {
        UserDefaults.standard.removeObject(forKey: "fv.onboarded")
        defer { UserDefaults.standard.removeObject(forKey: "fv.onboarded") }
        let base = TestSupport.makeTempDir("v431-onboard")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        let app = AppState(service: service)

        // No roots yet: refreshing must NOT mark onboarding.
        await app.refresh()
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "fv.onboarded"),
                       "an empty vault must keep the first-run guidance alive")

        // Adding the first folder is the completion event, whichever add
        // path produced it (quick-add sheet, settings, drag & drop).
        let folder = base + "/docs"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        TestSupport.write("hello", to: folder + "/note.md")
        try await service.addRoot(path: folder)
        await app.refresh()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "fv.onboarded"),
                      "protecting the first folder completes onboarding")
        try? FileManager.default.removeItem(atPath: base)
    }

    // MARK: - Remote address guard (v4.2.30 item 9; v4.2.31 relaxed in Core)

    func testIncompleteRemoteDetection() {
        // Complete forms pass — including the schemes the v4.2.30 cut
        // wrongly rejected (a real ssh:// or http:// remote must save).
        XCTAssertFalse(GitRemoteAddress.looksIncomplete("https://github.com/user/repo.git"))
        XCTAssertFalse(GitRemoteAddress.looksIncomplete("http://example.com/user/repo.git"))
        XCTAssertFalse(GitRemoteAddress.looksIncomplete("ssh://git@server/user/repo.git"))
        XCTAssertFalse(GitRemoteAddress.looksIncomplete("git://server/user/repo.git"))
        XCTAssertFalse(GitRemoteAddress.looksIncomplete("git@github.com:user/repo.git"))
        XCTAssertFalse(GitRemoteAddress.looksIncomplete("user@server:user/repo.git"))
        XCTAssertFalse(GitRemoteAddress.looksIncomplete("file:///Volumes/Backup/repo"))
        XCTAssertFalse(GitRemoteAddress.looksIncomplete("/local/path/repo.git"))
        XCTAssertFalse(GitRemoteAddress.looksIncomplete("  https://github.com/user/repo  "))
        // Empty means 仅本地, not "incomplete".
        XCTAssertFalse(GitRemoteAddress.looksIncomplete(""))
        XCTAssertFalse(GitRemoteAddress.looksIncomplete("   "))
        // The paste mistake the guard exists for: a bare host / fragment.
        XCTAssertTrue(GitRemoteAddress.looksIncomplete("github.com/user/repo"))
        XCTAssertTrue(GitRemoteAddress.looksIncomplete("https//github.com/user/repo"))
        // The settings save path shares the same rule.
        XCTAssertTrue(SettingsModel.looksIncompleteRemote("github.com/user/repo"))
        XCTAssertFalse(SettingsModel.looksIncompleteRemote("ssh://git@server/user/repo.git"))
    }

    // MARK: - Drag & drop validation (shared rule set, v4.2.31)

    func testDroppedFolderPathValidation() throws {
        let base = TestSupport.makeTempDir("v431-drop")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let dir = base + "/Folder"
        let file = base + "/notes.txt"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        TestSupport.write("x", to: file)
        let dirURL = URL(fileURLWithPath: dir)
        let fileURL = URL(fileURLWithPath: file)

        // One folder, not yet protected → adopted.
        XCTAssertEqual(QuickAddDrop.folderPath(from: [dirURL], isProtected: { _ in false }), dir)
        // Already protected → bounce (a silent success would mislead).
        XCTAssertNil(QuickAddDrop.folderPath(from: [dirURL], isProtected: { $0 == dir }))
        // A file, no items, or multiple items → bounce.
        XCTAssertNil(QuickAddDrop.folderPath(from: [fileURL], isProtected: { _ in false }))
        XCTAssertNil(QuickAddDrop.folderPath(from: [], isProtected: { _ in false }))
        XCTAssertNil(QuickAddDrop.folderPath(from: [dirURL, fileURL], isProtected: { _ in false }))
    }

    // MARK: - Create-repo dialog naming rule (v4.2.30 item 6a, pinned)

    func testCreateRepoSheetNameValidation() {
        XCTAssertTrue(CreateRepoSheet.isValidRepoName("my-notes"))
        XCTAssertTrue(CreateRepoSheet.isValidRepoName("My_Notes.2026"))
        XCTAssertTrue(CreateRepoSheet.isValidRepoName("a-b_c.d"))
        XCTAssertTrue(CreateRepoSheet.isValidRepoName("  spaced-trim-ok  "))
        // Empty / whitespace-only never reaches gh.
        XCTAssertFalse(CreateRepoSheet.isValidRepoName(""))
        XCTAssertFalse(CreateRepoSheet.isValidRepoName("   "))
        // Spaces, CJK and shell metacharacters must be blocked BEFORE the
        // button ever fires (the old dialog closed silently on them).
        XCTAssertFalse(CreateRepoSheet.isValidRepoName("my notes"))
        XCTAssertFalse(CreateRepoSheet.isValidRepoName("我的仓库"))
        XCTAssertFalse(CreateRepoSheet.isValidRepoName("a;b"))
    }

    // MARK: - Built-in support content (v4.2.30 item 10, pinned)

    func testFAQContentCoversTheEightSupportBasics() {
        let items = FAQContent.items
        XCTAssertEqual(items.count, 8, "the FAQ is documented as 8 answers (README v4.2.30)")
        for item in items {
            XCTAssertFalse(item.question.isEmpty)
            XCTAssertFalse(item.answer.isEmpty, "an answer without a next step is dead weight")
        }
        XCTAssertEqual(Set(items.map(\.question)).count, items.count, "questions must be distinct")
    }

    /// The shared 历史与恢复 window's two tabs are the canonical names every
    /// other surface points at (v4.2.30 terminology round).
    func testRecordsTabTitlesAreNonEmpty() {
        XCTAssertEqual(RecordsTab.allCases.count, 2)
        for tab in RecordsTab.allCases {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.symbol.isEmpty)
        }
    }

    // MARK: - Terminology regression (v4.2.30 round, pinned v4.2.31)

    /// The shared window's two tab names (「文件恢复」「历史时间线」) are the
    /// canonical surface names; the retired titles must not creep back into
    /// user-facing literals. Comments may mention the history; literals may not
    /// (same line-prefix comment skip as LocalizationTests).
    func testRetiredWindowNamesStayRetiredInSourceLiterals() throws {
        let bannedExact: Set<String> = [
            "历史版本",
            "远程仓库地址（可选）",
        ]
        let bannedContains = ["找回与还原", "打开主面板（⇧⌘D）"]
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let regex = try! NSRegularExpression(pattern: #""((?:[^\"\\\n]|\\.)*)""#)
        var offenders: [String] = []
        for dir in ["Sources/FileVaultApp", "Sources/FileVaultCore"] {
            let base = repoRoot.appendingPathComponent(dir)
            let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let raw = try String(contentsOf: url, encoding: .utf8)
                let ns = raw as NSString
                var offset = 0
                for line in raw.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
                        || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
                    if !isComment {
                        let range = NSRange(location: offset, length: (line as NSString).length)
                        for match in regex.matches(in: raw, range: range) {
                            let literal = ns.substring(with: match.range(at: 1))
                            if bannedExact.contains(literal)
                                || bannedContains.contains(where: literal.contains) {
                                offenders.append(url.lastPathComponent + ": " + literal)
                            }
                        }
                    }
                    offset += (line as NSString).length + 1
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "retired surface names reappeared as user-facing literals: "
                      + offenders.joined(separator: " | "))
    }
}
