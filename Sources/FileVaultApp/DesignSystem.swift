import SwiftUI
import FileVaultCore

// MARK: - Design tokens

/// One place for the app's visual language so the three windows stay consistent.
/// Deliberately built on semantic system colors + a single accent, so light/dark
/// and the user's accent color both keep working.
enum FVTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.075)
    static let cardStroke = Color.primary.opacity(0.07)
    /// Row highlight inside the menu-bar popover (v4.2.33).
    ///
    /// Two rules, both learned the hard way:
    ///
    /// 1. The popover already draws the system's vibrant menu material, so any
    ///    opaque fill (`card` is pure white in light mode) sat on it as a slab
    ///    — that is what «菜单有白色背景» meant. Rows paint only the system's
    ///    own highlight colour and let the material show through.
    /// 2. The highlight must be a *system semantic* colour, not a hand-mixed
    ///    `primary.opacity(…)≈grey`: macOS menus and inactive list selections
    ///    use `unemphasizedSelectedContentBackgroundColor` (#DCDCDC light /
    ///    #464646 dark), which is what «配色要与系统相符» asks for. A hand-mixed
    ///    wash drifted from the real highlight in both appearances.
    static let menuRowHover = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let radius: CGFloat = 14
    static let gutter: CGFloat = 20

    static let titleFont = Font.system(size: 23, weight: .semibold, design: .rounded)
    static let numberFont = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let sectionFont = Font.system(size: 12, weight: .semibold)
    static let rowFont = Font.system(size: 13)
    static let metaFont = Font.system(size: 11)
}

// MARK: - Card

private struct FVCardModifier: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(FVTheme.card)
                    .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(FVTheme.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    /// Rounded, hairline-bordered surface that floats slightly above the canvas.
    func fvCard(padding: CGFloat = 0, radius: CGFloat = FVTheme.radius) -> some View {
        modifier(FVCardModifier(padding: padding, radius: radius))
    }

    /// Full-bleed window canvas behind scrolling content.
    func fvCanvas() -> some View {
        background(FVTheme.canvas.ignoresSafeArea())
    }
}

// MARK: - Small parts

/// Tinted rounded-square glyph used as a visual anchor in headers and rows.
struct FVIconBadge: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(
                LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.62)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.28), radius: 5, x: 0, y: 2)
            // Decorative: the adjacent text carries the meaning; reading the
            // SF Symbol name aloud is noise for VoiceOver users (v4.2.27).
            .accessibilityHidden(true)
    }
}

/// Capsule status label: tinted text on a tinted wash.
struct FVStatusPill: View {
    let text: LocalizedStringKey
    var tint: Color = .green
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.13)))
        .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.16), lineWidth: 1))
    }
}

/// Section heading with an optional one-line explanation.
struct FVSectionHeader: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(FVTheme.sectionFont)
                if let subtitle {
                    Text(subtitle)
                        .font(FVTheme.metaFont)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(FVTheme.metaFont)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

/// Metric tile used in the dashboard's summary strip.
struct FVStatTile: View {
    let symbol: String
    let tint: Color
    let value: String
    let label: LocalizedStringKey
    var caption: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            FVIconBadge(symbol: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(FVTheme.numberFont)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .fvCard()
    }
}

/// Quiet empty state: glyph, one line of intent, optional hint and action.
struct FVEmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey? = nil
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            if let message {
                Text(message)
                    .font(FVTheme.metaFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 16)
    }
}

/// 1px separator that respects the card's horizontal inset.
struct FVHairline: View {
    var leading: CGFloat = 16
    var body: some View {
        Rectangle()
            .fill(FVTheme.hairline)
            .frame(height: 1)
            .padding(.leading, leading)
    }
}

// MARK: - Status semantics

enum FVStatusMeta {
    static func forSync(_ status: SyncStatus) -> (label: String, tint: Color, symbol: String) {
        // Translate at construction: the labels are consumed as String (menu
        // rows, accessibility text), where SwiftUI would not look them up.
        switch status {
        case .noRemote: return (NSLocalizedString("仅本地", comment: "sync status"), .secondary, "internaldrive")
        case .synced: return (NSLocalizedString("已同步", comment: "sync status"), .green, "checkmark.circle.fill")
        case .pendingPush: return (NSLocalizedString("待推送", comment: "sync status"), .orange, "arrow.up.circle.fill")
        case .pushing: return (NSLocalizedString("同步中", comment: "sync status"), .blue, "arrow.triangle.2.circlepath")
        case .failed: return (NSLocalizedString("失败", comment: "sync status"), .red, "exclamationmark.triangle.fill")
        }
    }
}

// MARK: - Formatting

enum FVTime {
    /// Locale of the app's current UI language (not the system default), so an
    /// English build never mixes "3 minutes ago" formatting with Chinese text —
    /// or, worse, shows Chinese relative dates in an otherwise English window.
    static var interfaceLocale: Locale {
        let code = Bundle.main.preferredLocalizations.first
            ?? Locale.current.identifier
        return Locale(identifier: code)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = interfaceLocale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func absolute(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute().locale(interfaceLocale))
    }

    static func absoluteWithSeconds(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute().second().locale(interfaceLocale))
    }
}

// MARK: - Legacy git path quoting

extension String {
    /// git with core.quotepath=true writes non-ASCII paths as octal escapes:
    /// "file20_\345\211\257\346\234\254.md". Commits created before the runner
    /// forced quotepath=false still carry that garbling, so display code decodes
    /// the byte runs (and drops the wrapping quotes) before rendering.
    var fvDecodingGitEscapes: String {
        let chars = Array(self)
        guard chars.contains("\\") else { return self }
        var out = ""
        var pending: [UInt8] = []
        var decodedAny = false
        // git wraps a C-quoted path in double quotes; only the WRAPPER pair must
        // be dropped. Removing every quote (the old behaviour) corrupted commit
        // messages that legitimately contained quotes (v4.2.26).
        var inQuotes = false

        func flush() {
            guard !pending.isEmpty else { return }
            out += String(decoding: pending, as: UTF8.self)
            pending.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            // git only octal-escapes inside a C-quoted run (quote_c_style
            // wraps the whole escaped path in double quotes). Requiring the
            // quote state keeps a literal "\\350" in a hand-written commit
            // subject from being decoded into replacement-character mojibake.
            if c == "\\", i + 3 < chars.count, inQuotes,
               let b0 = chars[i + 1].octalValue,
               let b1 = chars[i + 2].octalValue,
               let b2 = chars[i + 3].octalValue {
                pending.append(UInt8(b0 * 64 + b1 * 8 + b2))
                decodedAny = true
                i += 4
                continue
            }
            if c == "\\", i + 1 < chars.count, inQuotes {
                // Escaped quote / backslash inside the quoted path.
                flush()
                out.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "\"" {
                // Wrapper quotes are syntax, not content.
                flush()
                inQuotes.toggle()
                i += 1
                continue
            }
            flush()
            out.append(c)
            i += 1
        }
        flush()
        guard decodedAny else { return self }
        return out
    }
}

private extension Character {
    var octalValue: Int? {
        guard let digit = wholeNumberValue, ("0"..."7").contains(self) else { return nil }
        return digit
    }
}
