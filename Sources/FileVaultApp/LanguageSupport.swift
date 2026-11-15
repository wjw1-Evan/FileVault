import SwiftUI

/// App interface language (v3.4.0): Chinese (zh-Hans) + English, default follows
/// the macOS preferred language.
///
/// Implementation notes: the UI is written with Chinese literals that double as
/// lookup keys in `en.lproj/Localizable.strings`; SwiftUI resolves
/// `Text("中文")`-style literals automatically once the bundle carries the
/// localisation. Non-SwiftUI strings (notifications, status text, errors) call
/// `NSLocalizedString` for the same lookup. macOS picks the language from the
/// app's own `AppleLanguages` default, so switching takes one relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return NSLocalizedString("跟随系统", comment: "language option: follow macOS")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    /// Value written into the app's AppleLanguages default (nil = follow system).
    var appleLanguageCode: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "zh-Hans"
        case .en: return "en"
        }
    }

    static func storedValue(_ raw: String) -> AppLanguage {
        AppLanguage(rawValue: raw) ?? .system
    }

    /// Points the app at the chosen localisation. Takes effect on next launch.
    static func apply(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        if let code = language.appleLanguageCode {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }
}
