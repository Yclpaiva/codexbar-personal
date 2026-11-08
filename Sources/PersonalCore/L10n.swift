import Foundation

/// User-visible text. Keys are the English strings; `pt-BR.lproj` translates them. The bundle follows the
/// language order in System Settings and falls back to English.
public enum L10n {
    static let bundle: Bundle = {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("CodexBarPersonal_PersonalCore.bundle")
        return packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
    }()

    public static func tr(_ key: String) -> String {
        self.bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Formats with the user's locale, so numbers follow the region (for example, a decimal comma in Brazil).
    public static func tr(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: self.tr(key), locale: Locale.current, arguments: arguments)
    }
}
