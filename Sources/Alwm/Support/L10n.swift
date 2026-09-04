import Foundation
import SwiftUI
import AlwmL10n

/// Top spoken languages + system default. Codes match BCP-47 where practical.
public enum AppLanguage: String, Sendable, Codable, CaseIterable, Identifiable {
    case system
    case en
    case zhHans = "zh-Hans"
    case hi
    case es
    case fr
    case ar
    case bn
    case ptBR = "pt-BR"
    case ru
    case ur

    public var id: String { rawValue }

    /// Locale / table code (`system` resolves at runtime).
    public var code: String { rawValue }

    /// Native endonym for the picker (not localized). `.system` uses `L10n.t("language.system")` in UI.
    public var nativeName: String {
        switch self {
        case .system: return "System"
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .hi: return "हिन्दी"
        case .es: return "Español"
        case .fr: return "Français"
        case .ar: return "العربية"
        case .bn: return "বাংলা"
        case .ptBR: return "Português"
        case .ru: return "Русский"
        case .ur: return "اردو"
        }
    }

    public var isRTL: Bool {
        switch resolvedCode {
        case "ar", "ur": return true
        default: return false
        }
    }

    /// BCP-47 code actually used for lookups.
    public var resolvedCode: String {
        switch self {
        case .system: return AppLanguage.resolveSystemCode()
        default: return rawValue
        }
    }

    public var locale: Locale {
        Locale(identifier: resolvedCode)
    }

    public static func resolveSystemCode() -> String {
        let supported = Set(AppLanguage.allCases.compactMap { $0 == .system ? nil : $0.rawValue })
        for pref in Locale.preferredLanguages {
            let lower = pref.lowercased()
            if lower.hasPrefix("zh") {
                return "zh-Hans"
            }
            if lower.hasPrefix("pt") {
                return "pt-BR"
            }
            let primary = Locale(identifier: pref).language.languageCode?.identifier ?? String(pref.prefix(2))
            if supported.contains(primary) { return primary }
            if supported.contains(pref) { return pref }
            // zh-Hans-CN etc.
            for code in supported where lower.hasPrefix(code.lowercased()) {
                return code
            }
        }
        return "en"
    }
}

/// Runtime localization. Falls back to English, then the key.
@MainActor
public final class LocalizationController: ObservableObject {
    public static let shared = LocalizationController()

    @Published public private(set) var revision: UInt = 0
    @Published public private(set) var language: AppLanguage = .system

    private init() {}

    public func apply(_ language: AppLanguage) {
        self.language = language
        L10n.setLanguage(language)
        let code = language.resolvedCode
        PluginLocaleBridge.currentCode = code
        NotificationCenter.default.post(
            name: .alwmLanguageDidChange,
            object: nil,
            userInfo: ["code": code]
        )
        revision &+= 1
    }
}

public enum L10n {
    nonisolated(unsafe) private static var language: AppLanguage = .system

    public static func setLanguage(_ language: AppLanguage) {
        self.language = language
        PluginLocaleBridge.currentCode = language.resolvedCode
    }

    public static var current: AppLanguage { language }

    public static var resolvedCode: String { language.resolvedCode }

    public static var locale: Locale { language.locale }

    public static var layoutDirection: LayoutDirection {
        language.isRTL ? .rightToLeft : .leftToRight
    }

    public static func t(_ key: String) -> String {
        let code = language.resolvedCode
        if let value = L10nTables.tables[code]?[key] { return value }
        if let value = L10nTables.tables["en"]?[key] { return value }
        return key
    }

    public static func tf(_ key: String, _ args: CVarArg...) -> String {
        let format = t(key)
        return String(format: format, locale: locale, arguments: args)
    }
}

public struct AlwmLocaleModifier: ViewModifier {
    @ObservedObject private var loc = LocalizationController.shared

    public func body(content: Content) -> some View {
        content
            .environment(\.locale, L10n.locale)
            .environment(\.layoutDirection, L10n.layoutDirection)
            .id(loc.revision)
    }
}

public extension View {
    func alwmLocalized() -> some View {
        modifier(AlwmLocaleModifier())
    }
}
