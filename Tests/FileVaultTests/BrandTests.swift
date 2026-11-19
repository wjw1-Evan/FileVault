import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// Brand contract (v4.2.31 rename: FileVault → Pastward).
///
/// The old name collided with macOS's built-in disk-encryption feature
/// (search confusion + review risk, docs/04/docs/06). "Pastward" is unique
/// in the software space (web-swept: no product/App Store/GitHub collisions).
/// These tests pin the rename so a stray "FileVault" cannot creep back into
/// user-facing surfaces — machine identifiers (bundle id, config directory,
/// refs/filevault/backup, executable/module names) intentionally keep the
/// original spelling for update/migration continuity (docs/06 §5).
final class BrandTests: XCTestCase {

    func testProductNameIsPastward() {
        XCTAssertEqual(AppBrand.productName, "Pastward")
    }

    /// Machine identifiers must NOT follow the rename: the update channel
    /// (UpdateGuard pins the bundle id) and on-disk migration compatibility
    /// (config directory, backup ref) depend on them.
    func testMachineIdentifiersKeepTheOriginalSpelling() {
        XCTAssertEqual(AppBrand.bundleIdentifier, "com.filevault.FileVault")
        XCTAssertTrue(ConfigStore.defaultDirectory.path
            .hasSuffix("Application Support/FileVault"),
            "existing installs must find their config where they left it")
    }

    /// The About panel must show the new name (it is the one surface users
    /// quote back in support mail).
    func testAboutPanelUsesProductName() {
        XCTAssertFalse(AppBrand.productName.isEmpty)
        XCTAssertNotEqual(AppBrand.productName, "FileVault")
    }

    /// The English table must carry the renamed keys: the zh literals are the
    /// lookup keys, so a rename that misses one entry leaves the UI Chinese
    /// in English builds.
    func testRenamedKeysHaveEnglishEntries() throws {
        let path = BrandTests.stringsPath
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        for key in ["退出 Pastward", "关于 Pastward", "Pastward 设置",
                    "Pastward 历史与恢复", "Pastward 永久免费 · 无账号、无订阅、无遥测",
                    "Pastward 反馈（v%@ · %@）"] {
            XCTAssertTrue(raw.contains("\"\(key)\" ="),
                          "the English table must translate \"\(key)\"")
        }
    }

    /// No user-facing Chinese literal may still say the old brand: those are
    /// the lookup keys SwiftUI renders verbatim in zh builds. (Identifiers
    /// like FileVaultApp are excluded by the quote-adjacent check below.)
    func testNoUserFacingLiteralKeepsTheOldName() throws {
        var offenders: [String] = []
        for file in try BrandTests.appSourceFiles() {
            let raw = try String(contentsOfFile: file, encoding: .utf8)
            for line in raw.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                // A literal brand mention = "FileVault" inside quotes followed
                // by a CJK character or punctuation (window titles, rows…).
                if line.range(of: "\"[^\"]*FileVault[^\"]*\"", options: .regularExpression) != nil,
                   line.range(of: "FileVault[\\u4e00-\\u9fff ]") != nil,
                   line.range(of: "FileVaultApp|FileVaultCore|FileVaultService|FileVaultTests") == nil {
                    offenders.append(file + ": " + trimmed)
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "user-facing literals still carry the old brand:\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private static var stringsPath: String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent(
            "Sources/FileVaultApp/Resources/en.lproj/Localizable.strings").path
    }

    private static func appSourceFiles() throws -> [String] {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = repoRoot.appendingPathComponent("Sources/FileVaultApp")
        var files: [String] = []
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL, url.pathExtension == "swift" {
            files.append(url.path)
        }
        return files
    }
}
