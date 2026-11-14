import AppKit

/// FileVault design tokens (v2.0.0 unified UI language).
enum FVDesign {
    static let cardWidth: CGFloat = 586
    static let cornerRadius: CGFloat = 10
    static let margin: CGFloat = 14
    static let spacing: CGFloat = 8

    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let captionFont = NSFont.systemFont(ofSize: 11)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// A rounded, bordered card container pre-configured with tokens.
    static func card() -> NSStackView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = spacing
        card.edgeInsets = NSEdgeInsets(top: 12, left: margin, bottom: 12, right: margin)
        card.wantsLayer = true
        card.layer?.cornerRadius = cornerRadius
        card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 1
        return card
    }

    /// Section header inside a card (small, semibold).
    static func header(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        return l
    }

    /// Secondary caption line.
    static func caption(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = captionFont
        l.textColor = .secondaryLabelColor
        return l
    }

    /// Horizontal separator.
    static func separator() -> NSView {
        let sep = NSBox()
        sep.boxType = .separator
        return sep
    }

    /// Standard rounded action button.
    static func button(_ title: String, action: Selector, target: AnyObject?, identifier: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.identifier = NSUserInterfaceItemIdentifier(identifier ?? title)
        return b
    }

    /// Status glyph image view (colored SF Symbol).
    static func statusGlyph(_ symbol: String, _ color: NSColor, pointSize: CGFloat = 12) -> NSImageView {
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "状态")?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        iv.contentTintColor = color
        return iv
    }
}
