import Foundation

/// Central product/brand metadata.
///
/// Everything user-facing that a rename or rebrand would touch lives here.
/// v4.2.31: the product was renamed FileVault → PASTWARD — the old name
/// collided with macOS's built-in disk-encryption feature (search confusion
/// + review risk, see docs/04/docs/06). "Pastward" (modeled on
/// backward/afterward) is unique in the software space (verified by a web
/// sweep: no product/App Store/GitHub collisions), and matches the product's
/// one job: take files back to the past.
///
/// Machine identifiers intentionally keep the ORIGINAL spelling so existing
/// installs update and migrate transparently (docs/06 §5): bundle id
/// com.filevault.FileVault (UpdateGuard pins it), the config directory
/// ~/Library/Application Support/FileVault, the git backup ref
/// refs/filevault/backup, and the FileVaultApp executable/module names.
public enum AppBrand {
    public static let productName = "Pastward"
    public static let bundleIdentifier = "com.filevault.FileVault"
    public static let minimumMacOS = "14.0"

    /// Support / feedback channel (shown in About + 诊断包).
    public static let supportEmail = "support@filevault.app"
    /// Project home (docs, releases, issue tracker).
    public static let websiteURL = "https://github.com/wjw1-Evan/FileVault"
    /// Privacy policy (also shipped as PRIVACY.md in the repo).
    public static let privacyURL = "https://github.com/wjw1-Evan/FileVault/blob/main/PRIVACY.md"

    /// FileVault is free to use, with no account, trial or activation.
    public static let pricingNote = NSLocalizedString("永久免费", comment: "pricing note")
}
