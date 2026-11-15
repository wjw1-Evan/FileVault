import AppKit
import FileVaultCore

/// Simple .gitignore editor window (FR-14).
final class GitignoreEditorController: NSWindowController, NSTextViewDelegate {
    private let repoPath: String
    private let repos: RepoManager?
    private var textView: NSTextView?
    var onSaved: (() -> Void)?

    init(repoPath: String, repos: RepoManager?) {
        self.repoPath = repoPath
        self.repos = repos
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "忽略规则 — " + (repoPath as NSString).lastPathComponent
        win.minSize = NSSize(width: 480, height: 320)
        super.init(window: win)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.edgeInsets = NSEdgeInsets(top: 12, left: FVDesign.margin, bottom: 12, right: FVDesign.margin)
        container.wantsLayer = true
        container.layer?.cornerRadius = FVDesign.cornerRadius
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.borderWidth = 1
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.hasVerticalScroller = true
        let tv = NSTextView(frame: scroll.bounds)
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.autoresizingMask = [.width]
        tv.isEditable = true
        tv.isSelectable = true
        tv.string = repos?.gitignore(path: repoPath) ?? ""
        self.textView = tv
        scroll.documentView = tv
        container.addArrangedSubview(scroll)
        let save = NSButton(title: "保存（改动会被自动提交）", target: nil, action: nil)
        save.bezelStyle = .rounded
        save.target = self
        save.action = #selector(saveAction)
        container.addArrangedSubview(save)
        window?.contentView = container
    }

    @objc private func saveAction() {
        repos?.saveGitignore(path: repoPath, content: textView?.string ?? "")
        onSaved?()
        window?.close()
    }
}
