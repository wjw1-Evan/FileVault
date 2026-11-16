import Foundation

/// v4.2.13: advise when a protected folder lives inside a cloud-sync provider.
/// On-demand placeholders (iCloud "优化 Mac 存储", Dropbox/OneDrive online-only
/// files) can look like deleted files to git, so the app surfaces this directly
/// instead of leaving the user to wonder why history shows deletions.
public enum CloudFolderAdvice {
    // (v4.2.26) Google Drive on modern macOS mounts under
    // ~/Library/CloudStorage/GoogleDrive-<account>, which the old path table
    // did not recognise: the placeholder warning silently never appeared.
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
        // Modern macOS mounts third-party providers under
        // ~/Library/CloudStorage/<Provider>[-account] (v4.2.26).
        if lower.contains("/library/cloudstorage/") {
            if lower.contains("/cloudstorage/googledrive") { return "Google Drive" }
            if lower.contains("/cloudstorage/onedrive") { return "OneDrive" }
            if lower.contains("/cloudstorage/dropbox") { return "Dropbox" }
            if lower.contains("/cloudstorage/box") { return "Box" }
        }
        return nil
    }
}
