import Foundation

/// Central product/brand metadata.
///
/// Everything user-facing that a rename or rebrand would touch lives here:
/// the trademark/App Store review risk of the current name "FileVault"
/// (it collides with macOS's disk-encryption feature) is documented in
/// docs/04 and docs/06 — when the rename happens, this is the file to edit.
public enum AppBrand {
    public static let productName = "FileVault"
    public static let bundleIdentifier = "com.filevault.FileVault"
    public static let minimumMacOS = "14.0"

    /// Support / feedback channel (shown in About + 诊断包).
    public static let supportEmail = "support@filevault.app"
    /// Project home (docs, releases, issue tracker).
    public static let websiteURL = "https://github.com/wjw1-Evan/FileVault"
    /// Privacy policy (also shipped as PRIVACY.md in the repo).
    public static let privacyURL = "https://github.com/wjw1-Evan/FileVault/blob/main/PRIVACY.md"

    /// FileVault is free to use, with no account, trial or activation.
    public static let pricingNote = "永久免费"
}
