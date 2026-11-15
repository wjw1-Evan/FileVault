import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// Localisation coverage (v3.4.0): zh-Hans literals are the keys, en.lproj holds
/// the English values; language choice is persisted and applied via AppleLanguages.
final class LocalizationTests: XCTestCase {
    /// Path to the shipped localisation table (repo-relative via #filePath).
    private static var stringsPath: String {
        let thisFile = URL(fileURLWithPath: #filePath)          // Tests/FileVaultTests/<this>.swift
        let repoRoot = thisFile.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Sources/FileVaultApp/Resources/en.lproj/Localizable.strings").path
    }

    private static func parseStrings() throws -> [String: String] {
        let raw = try String(contentsOfFile: stringsPath, encoding: .utf8)
        var table: [String: String] = [:]
        // "key" = "value";
        let pattern = #""((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = raw as NSString
        for match in regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1))
            let value = ns.substring(with: match.range(at: 2))
            XCTAssertNil(table[key], "duplicate key: \(key)")
            table[key] = value
        }
        return table
    }

    func testStringsTableParsesAndIsNonEmpty() throws {
        let table = try Self.parseStrings()
        XCTAssertGreaterThan(table.count, 200, "expected a substantial English table")
        for (key, value) in table {
            XCTAssertFalse(value.isEmpty, "empty translation for: \(key)")
        }
    }

    func testPlaceholdersMatchBetweenLanguages() throws {
        let table = try Self.parseStrings()
        for (key, value) in table {
            let keyPlaceholders = key.components(separatedBy: "%").count - 1
            let valuePlaceholders = value.components(separatedBy: "%").count - 1
            XCTAssertEqual(keyPlaceholders, valuePlaceholders,
                           "placeholder mismatch for: \(key) → \(value)")
        }
    }

    /// Every Chinese literal that SwiftUI/NSLocalizedString would localise must
    /// have an English entry — otherwise the app silently falls back to Chinese.
    func testEveryUserFacingChineseLiteralHasEnglishTranslation() throws {
        let table = try Self.parseStrings()
        // Fragments that are intentionally translated as part of a format string.
        // Language names stay in their own language; fragments live in format strings.
        let exempt: Set<String> = ["…", "，", " · ", "简体中文", "English"]
        var missing: [String] = []
        for file in try sourceFiles() {
            let raw = try String(contentsOfFile: file, encoding: .utf8)
            for literal in chineseLiterals(in: raw) where !exempt.contains(literal) {
                if table[literal] == nil { missing.append(literal) }
            }
        }
        XCTAssertTrue(missing.isEmpty,
                      "missing English translations (\(missing.count)): \(Set(missing).sorted().joined(separator: " | "))")
    }

    func testLanguageStorageResolution() {
        XCTAssertEqual(AppLanguage.storedValue("en"), .en)
        XCTAssertEqual(AppLanguage.storedValue("zh-Hans"), .zhHans)
        XCTAssertEqual(AppLanguage.storedValue("system"), .system)
        XCTAssertEqual(AppLanguage.storedValue("garbage"), .system, "unknown value falls back to system")
        XCTAssertNil(AppLanguage.system.appleLanguageCode)
        XCTAssertEqual(AppLanguage.en.appleLanguageCode, "en")
        XCTAssertEqual(AppLanguage.zhHans.appleLanguageCode, "zh-Hans")
        for lang in AppLanguage.allCases {
            XCTAssertFalse(lang.displayName.isEmpty)
        }
    }

    func testApplyingLanguageWritesAppleLanguages() {
        let suiteName = "fv.language.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        AppLanguage.apply(.en, defaults: suite)
        XCTAssertEqual(suite.array(forKey: "AppleLanguages") as? [String], ["en"])
        AppLanguage.apply(.zhHans, defaults: suite)
        XCTAssertEqual(suite.array(forKey: "AppleLanguages") as? [String], ["zh-Hans"])
        AppLanguage.apply(.system, defaults: suite)
        let suiteDomain = suite.persistentDomain(forName: suiteName)
        XCTAssertNil(suiteDomain?["AppleLanguages"], "system choice removes the override")
    }

    func testConfigPersistsLanguageAndRejectsUnknown() {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("langcfg"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        var cfg = store.load()
        cfg.general.language = "en"
        store.save(cfg)
        XCTAssertEqual(ConfigStore(directory: dir).load().general.language, "en")

        // Unknown / stale values must not break loading.
        var bad = cfg
        bad.general.language = "klingon"
        store.save(bad)
        XCTAssertEqual(ConfigStore(directory: dir).load().general.language, "system",
                       "unknown stored values are normalised to system")
        XCTAssertEqual(AppLanguage.storedValue(ConfigStore(directory: dir).load().general.language), .system)
    }

    // MARK: - Source scanning helpers

    private func sourceFiles() throws -> [String] {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files: [String] = []
        for dir in ["Sources/FileVaultApp", "Sources/FileVaultCore"] {
            let base = repoRoot.appendingPathComponent(dir)
            let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension == "swift" { files.append(url.path) }
            }
        }
        return files
    }

    /// Chinese string literals, skipping comments and interpolated strings
    /// (those are covered by their format-string entries).
    private func chineseLiterals(in source: String) -> [String] {
        var result: [String] = []
        let regex = try! NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
        let ns = source as NSString
        let lines = source.components(separatedBy: "\n")
        var offset = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
            if !isComment {
                let range = NSRange(location: offset, length: (line as NSString).length)
                for match in regex.matches(in: source, range: range) {
                    let literal = ns.substring(with: match.range(at: 1))
                    if literal.contains("\\(") { continue }
                    if literal.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil {
                        result.append(literal)
                    }
                }
            }
            offset += (line as NSString).length + 1
        }
        return result
    }
}
