import AlwmL10n
import Testing
@testable import Alwm

@Suite("Notepad localization")
struct NotepadLocalizationTests {
    @Test("all app locales translate every notepad string")
    func everyAppLocaleHasNotepadStrings() {
        let english = L10nTables.tables["en"] ?? [:]
        let keys = english.keys.filter {
            $0.hasPrefix("notepad.") ||
            $0.hasPrefix("action.notepad.") ||
            $0 == "menu.notepad" ||
            $0 == "menu.notepad.recent" ||
            $0.hasPrefix("pane.notepad")
        }
        let locales = AppLanguage.allCases
            .filter { $0 != .system && $0 != .en }
            .map(\.code)

        for locale in locales {
            let table = L10nTables.tables[locale] ?? [:]
            for key in keys {
                #expect(table[key] != nil, "\(locale) is missing \(key)")
            }
        }
    }
}
