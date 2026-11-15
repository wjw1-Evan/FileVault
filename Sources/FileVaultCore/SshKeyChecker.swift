import Foundation

/// Detects SSH keys under a directory (default ~/.ssh) to guide remote setup (FR-15).
public final class SshKeyChecker: @unchecked Sendable {
    public let sshDirectory: String

    public init(sshDirectory: String? = nil) {
        if let sshDirectory {
            self.sshDirectory = sshDirectory
        } else {
            self.sshDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        }
    }

    /// Public keys usually present: id_ed25519.pub / id_rsa.pub / id_ecdsa.pub.
    public var hasPublicKey: Bool {
        !publicKeys().isEmpty
    }

    public func publicKeys() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: sshDirectory) else { return [] }
        return items.filter { $0.hasSuffix(".pub") }.sorted()
    }

    /// Human-readable guidance shown in settings when SSH remote is configured without a key.
    public var guidance: String? {
        hasPublicKey ? nil : NSLocalizedString("未检测到 SSH 密钥。请在终端运行 ssh-keygen 生成，并把公钥添加到你的 Git 托管平台。", comment: "ssh guidance")
    }
}
