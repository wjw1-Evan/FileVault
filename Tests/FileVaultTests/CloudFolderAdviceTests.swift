import XCTest
@testable import FileVaultCore

/// v4.2.13: protected folders inside cloud-sync providers are flagged in the UI,
/// because on-demand placeholders can look like deleted files to git.
final class CloudFolderAdviceTests: XCTestCase {
    func testDetectsKnownCloudProviders() {
        XCTAssertEqual(CloudFolderAdvice.provider(for: "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Notes"),
                       "iCloud Drive")
        XCTAssertEqual(CloudFolderAdvice.provider(for: "/Users/a/Dropbox/Work"), "Dropbox")
        XCTAssertEqual(CloudFolderAdvice.provider(for: "/Users/a/Dropbox"), "Dropbox")
        XCTAssertEqual(CloudFolderAdvice.provider(for: "/Users/a/OneDrive - Contoso/Docs"), "OneDrive")
        XCTAssertEqual(CloudFolderAdvice.provider(for: "/Volumes/X/Google Drive/notes"), "Google Drive")
        XCTAssertNil(CloudFolderAdvice.provider(for: "/Users/a/Documents/notes"))
        XCTAssertNil(CloudFolderAdvice.provider(for: "/Users/a/dropboxish/notes"))
    }
}
