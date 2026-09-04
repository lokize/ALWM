import Foundation

/// Process-wide language for plugins.
///
/// `AlwmL10n` is linked statically into the host and each plugin dylib, so an in-memory
/// static would not be shared. UserDefaults is process-wide and keeps them in sync.
public enum PluginLocaleBridge {
    public static let defaultsKey = "dev.alwm.languageCode"

    public static var currentCode: String {
        get {
            if let stored = UserDefaults.standard.string(forKey: defaultsKey), !stored.isEmpty {
                return stored
            }
            return PluginL10n.resolveSystemPreferredCode()
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
        }
    }
}

public extension Notification.Name {
    static let alwmLanguageDidChange = Notification.Name("dev.alwm.languageDidChange")
}

/// Locale-aware lookups for bundled plugins. Languages match `L10nTables` (app languages).
public enum PluginL10n {
    /// Same codes as the app (excluding `.system`).
    public static var supportedCodes: [String] {
        L10nTables.tables.keys.sorted()
    }

    /// Current app language code (Settings → Language / macOS when System).
    public static var currentCode: String {
        resolveCode(PluginLocaleBridge.currentCode)
    }

    public static func t(_ key: String, locale code: String? = nil) -> String {
        let resolved = resolveCode(code ?? PluginLocaleBridge.currentCode)
        if let value = PluginStrings.tables[resolved]?[key] { return value }
        if let value = L10nTables.tables[resolved]?[key] { return value }
        if let value = PluginStrings.tables["en"]?[key] { return value }
        if let value = L10nTables.tables["en"]?[key] { return value }
        return key
    }

    public static func tf(_ key: String, locale code: String? = nil, _ args: CVarArg...) -> String {
        let resolved = resolveCode(code ?? PluginLocaleBridge.currentCode)
        let format = t(key, locale: resolved)
        return String(format: format, locale: Locale(identifier: resolved), arguments: args)
    }

    public static func resolveCode(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("zh") { return "zh-Hans" }
        if lower.hasPrefix("pt") { return "pt-BR" }
        let supported = Set(L10nTables.tables.keys)
        if supported.contains(raw) { return raw }
        let primary = Locale(identifier: raw).language.languageCode?.identifier ?? String(raw.prefix(2))
        if supported.contains(primary) { return primary }
        for code in supported where lower.hasPrefix(code.lowercased()) {
            return code
        }
        return "en"
    }

    /// Mirrors app `.system` resolution using preferred languages.
    public static func resolveSystemPreferredCode() -> String {
        let supported = Set(L10nTables.tables.keys)
        for pref in Locale.preferredLanguages {
            let lower = pref.lowercased()
            if lower.hasPrefix("zh") { return "zh-Hans" }
            if lower.hasPrefix("pt") { return "pt-BR" }
            let primary = Locale(identifier: pref).language.languageCode?.identifier ?? String(pref.prefix(2))
            if supported.contains(primary) { return primary }
            if supported.contains(pref) { return pref }
            for code in supported where lower.hasPrefix(code.lowercased()) {
                return code
            }
        }
        return "en"
    }
}
