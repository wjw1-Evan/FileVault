import AppKit
import FileVaultCore

/// Small progress window shown during auto-update (FR-20 v1.2.2).
final class UpdateProgressWindowController: NSWindowController {
    private let stageLabel = NSTextField(labelWithString: "准备更新…")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title = "FileVault 更新"
        win.titlebarAppearsTransparent = true
        win.center()
        super.init(window: win)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "正在更新 FileVault")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(stageLabel)
        bar.isIndeterminate = true
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.frame = NSRect(x: 0, y: 0, width: 330, height: 6)
        stack.addArrangedSubview(bar)
        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(detailLabel)

        bar.widthAnchor.constraint(equalToConstant: 330).isActive = true
        let host = NSView()
        window?.contentView = host
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
    }

    /// Update the stage; fraction non-nil switches to a determinate bar.
    @MainActor
    func setStage(_ text: String, fraction: Double? = nil, detail: String = "") {
        stageLabel.stringValue = text
        detailLabel.stringValue = detail
        if let fraction {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func closeWindow() {
        window?.orderOut(nil)
    }
}
