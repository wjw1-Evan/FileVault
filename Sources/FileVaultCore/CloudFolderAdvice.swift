import Foundation

/// v4.2.13: advise when a protected folder lives inside a cloud-sync provider.
/// On-demand placeholders (iCloud "优化 Mac 存储", Dropbox/OneDrive online-only
/// files) can look like deleted files to git, so the app surfaces this directly
/// instead of leaving the user to wonder why history shows deletions.
public enum CloudFolderAdvice {
    /// Display name of the cloud provider containing this path, if any.
    public static func provider(for path: String) -> String? {
        let lower = path.lowercased()
        if lower.contains("/library/mobile documents/com~apple~clouddocs") {
            return "iCloud Drive"
        }
        if lower.contains("/dropbox/") || lower.hasSuffix("/dropbox") {
            return "Dropbox"
        }
        if lower.contains("/onedrive") {
            return "OneDrive"
        }
        if lower.contains("/google drive/") || lower.hasSuffix("/google drive") {
            return "Google Drive"
        }
        return nil
    }
}
