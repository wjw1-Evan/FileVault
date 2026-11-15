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

    /// Single-line (outline, template) icon for menus and labels.
    static func lineIcon(_ symbol: String, pointSize: CGFloat = 12) -> NSImage? {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        img?.isTemplate = true
        return img
    }

    /// Modal alert attached as a SHEET to `host` when possible: sheets do not
    /// depend on activation policy at all, which makes them the robust modal
    /// for a menu-bar app (accessory apps' self-activation is cooperatively
    /// ignored on modern macOS — invisible-modal bug caught by live button
    /// testing, v2.6.7). Falls back to a promoted runModal without a host.
    @MainActor
    static func activateAndRunModal(_ alert: NSAlert, on host: NSWindow?) async -> NSApplication.ModalResponse {
        if let host, host.isVisible {
            return await withCheckedContinuation { cont in
                alert.beginSheetModal(for: host) { resp in cont.resume(returning: resp) }
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        NSApp.setActivationPolicy(.accessory)
        return response
    }

    /// Sheet-modal open panel — same rationale as `activateAndRunModal`.
    @MainActor
    static func activateAndRunPanel(_ panel: NSOpenPanel, on host: NSWindow?) async -> NSApplication.ModalResponse {
        if let host, host.isVisible {
            return await withCheckedContinuation { cont in
                panel.beginSheetModal(for: host) { resp in cont.resume(returning: resp) }
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        NSApp.setActivationPolicy(.accessory)
        return response
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
