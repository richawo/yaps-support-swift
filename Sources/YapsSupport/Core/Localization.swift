import Foundation
import SwiftUI

/// Picks the SDK's UI language and looks up its strings from the package's String Catalog.
enum Localization {
    static let supported = [
        "en", "es", "fr", "de", "it", "pt-BR", "nl", "sv", "pl", "tr", "ru", "uk",
        "ar", "he", "hi", "ja", "ko", "zh-Hans", "zh-Hant", "id", "vi", "th",
    ]

    static let rightToLeft: Set<String> = ["ar", "he"]

    /// Resolves the language from an override or the app's preferred localizations.
    static func resolve(override: String?, preferred: [String] = Bundle.main.preferredLocalizations + Locale.preferredLanguages) -> String {
        if let override, let match = match(override) { return match }
        for tag in preferred {
            if let match = match(tag) { return match }
        }
        return "en"
    }

    /// Matches a BCP 47 tag (or `en_GB` style identifier) to a supported localization.
    static func match(_ tag: String) -> String? {
        let normalized = tag.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        guard let primary = parts.first?.lowercased(), !primary.isEmpty else { return nil }
        switch primary {
        case "zh":
            let rest = parts.dropFirst().map { $0.lowercased() }
            if rest.contains("hant") || rest.contains("tw") || rest.contains("hk") || rest.contains("mo") { return "zh-Hant" }
            return "zh-Hans"
        case "pt": return "pt-BR"
        case "iw": return "he"
        case "in": return "id"
        case "nb", "no": return nil
        default:
            return supported.first { $0.lowercased() == primary }
        }
    }

    static func isRightToLeft(_ language: String) -> Bool {
        rightToLeft.contains(String(language.split(separator: "-").first ?? ""))
    }

    static func locale(for language: String) -> Locale { Locale(identifier: language) }

    private static let bundles = BundleCache()

    static func bundle(for language: String) -> Bundle {
        bundles.bundle(for: language)
    }

    static func string(_ key: String, language: String) -> String {
        let value = bundle(for: language).localizedString(forKey: key, value: nil, table: "Localizable")
        if value != key { return value }
        let english = bundle(for: "en").localizedString(forKey: key, value: nil, table: "Localizable")
        return english
    }

    private final class BundleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: Bundle] = [:]

        func bundle(for language: String) -> Bundle {
            lock.lock(); defer { lock.unlock() }
            if let cached = cache[language] { return cached }
            let candidates = [language, language.lowercased(), language.replacingOccurrences(of: "-", with: "_")]
            for candidate in candidates {
                if let path = Bundle.module.path(forResource: candidate, ofType: "lproj"), let bundle = Bundle(path: path) {
                    cache[language] = bundle
                    return bundle
                }
            }
            cache[language] = Bundle.module
            return Bundle.module
        }
    }
}

/// Localized strings for the current SDK language, passed through the SwiftUI environment.
struct Strings: Sendable {
    let language: String

    func callAsFunction(_ key: String) -> String { Localization.string(key, language: language) }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: Localization.string(key, language: language), locale: Localization.locale(for: language), arguments: arguments)
    }

    var locale: Locale { Localization.locale(for: language) }
    var layoutDirection: LayoutDirection { Localization.isRightToLeft(language) ? .rightToLeft : .leftToRight }
}

private struct StringsKey: EnvironmentKey {
    static let defaultValue = Strings(language: "en")
}

extension EnvironmentValues {
    var supportStrings: Strings {
        get { self[StringsKey.self] }
        set { self[StringsKey.self] = newValue }
    }
}
