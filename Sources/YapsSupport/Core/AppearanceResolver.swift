import SwiftUI
import UIKit

/// Where a resolved colour came from. Kept symbolic so precedence is testable.
enum ThemeColor: Equatable {
    case remote(ColorPair)
    case local(Color)
    case standard(Standard)

    enum Standard: Equatable {
        case accent, onAccent, background, incomingBackground, incomingForeground
    }

    var color: Color {
        switch self {
        case .remote(let pair):
            return Color(uiColor: UIColor { traits in
                let hex = traits.userInterfaceStyle == .dark ? pair.dark : pair.light
                return UIColor(hex: hex) ?? .systemBlue
            })
        case .local(let color):
            return color
        case .standard(let standard):
            switch standard {
            case .accent: return Color.accentColor
            case .onAccent: return .white
            case .background: return Color(uiColor: .systemBackground)
            case .incomingBackground: return Color(uiColor: .secondarySystemBackground)
            case .incomingForeground: return Color(uiColor: .label)
            }
        }
    }
}

enum ResolvedWelcomeIcon {
    case symbol(String)
    case image(Image)
    case url(URL)
    case hidden
}

/// The appearance the chat actually uses, after applying remote > local > default.
struct ResolvedAppearance {
    var accent: ThemeColor
    var onAccent: ThemeColor
    var background: ThemeColor
    var incomingBackground: ThemeColor
    var incomingForeground: ThemeColor
    var title: String
    var welcomeTitle: String
    var welcomeText: String
    var fontDesign: SupportAppearance.FontDesign
    var cornerStyle: SupportAppearance.CornerStyle
    var colorScheme: SupportAppearance.ColorSchemePreference
    var showsCloseButton: Bool
    var closeIcon: SupportAppearance.CloseIcon
    var welcomeIcon: ResolvedWelcomeIcon
    var fadesOlderMessages: Bool

    static let defaultWelcomeSymbol = "bubble.left.and.bubble.right.fill"

    var font: Font.Design {
        switch fontDesign {
        case .default: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }

    var bubbleRadius: CGFloat {
        switch cornerStyle {
        case .round: return 20
        case .soft: return 12
        case .square: return 5
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch colorScheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppearanceResolver {
    /// Resolves the appearance. `remote` is ignored when `nil` (no published appearance or
    /// `usesRemoteAppearance == false`). `language` is the SDK's resolved language code.
    static func resolve(remote: RemoteAppearance?, local: SupportAppearance, language: String,
                        strings: (String) -> String) -> ResolvedAppearance {
        func color(_ pair: ColorPair?, _ local: Color?, _ standard: ThemeColor.Standard) -> ThemeColor {
            if let pair, UIColor(hex: pair.light) != nil, UIColor(hex: pair.dark) != nil { return .remote(pair) }
            if let local { return .local(local) }
            return .standard(standard)
        }

        func text(_ map: [String: String]?, _ local: String?, defaultKey: String) -> String {
            if let value = localizedValue(map, language: language) { return value }
            if let local, !local.isEmpty { return local }
            return strings(defaultKey)
        }

        let colors = remote?.colors
        let welcomeIcon: ResolvedWelcomeIcon
        if let urlString = remote?.welcomeIconUrl, let url = URL(string: urlString), url.scheme == "https" {
            welcomeIcon = .url(url)
        } else {
            switch local.welcomeIcon {
            case .symbol(let name): welcomeIcon = .symbol(name)
            case .image(let image): welcomeIcon = .image(image)
            case .url(let url): welcomeIcon = .url(url)
            case .hidden: welcomeIcon = .hidden
            case nil: welcomeIcon = .symbol(ResolvedAppearance.defaultWelcomeSymbol)
            }
        }

        return ResolvedAppearance(
            accent: color(colors?.accent, local.accentColor, .accent),
            onAccent: color(colors?.onAccent, local.onAccentColor, .onAccent),
            background: color(colors?.background, local.backgroundColor, .background),
            incomingBackground: color(colors?.incomingBackground, local.incomingBackgroundColor, .incomingBackground),
            incomingForeground: color(colors?.incomingForeground, local.incomingForegroundColor, .incomingForeground),
            title: text(remote?.title, local.title, defaultKey: "chat.title"),
            welcomeTitle: text(remote?.welcomeTitle, local.welcomeTitle, defaultKey: "welcome.title"),
            welcomeText: text(remote?.welcomeText, local.welcomeText, defaultKey: "welcome.text"),
            fontDesign: remote?.fontStyle.flatMap(fontDesign(from:)) ?? local.fontDesign ?? .default,
            cornerStyle: remote?.cornerStyle.flatMap(SupportAppearance.CornerStyle.init(rawValue:)) ?? local.cornerStyle ?? .round,
            colorScheme: remote?.colorScheme.flatMap(SupportAppearance.ColorSchemePreference.init(rawValue:)) ?? local.colorScheme ?? .system,
            showsCloseButton: remote?.showCloseButton ?? local.showsCloseButton ?? true,
            closeIcon: local.closeIcon,
            welcomeIcon: welcomeIcon,
            fadesOlderMessages: remote?.fadeOlderMessages ?? local.fadesOlderMessages ?? false
        )
    }

    /// Picks the text for `language` from a remote map: exact match, then the primary subtag,
    /// then `en`. Returns nil when the map has none of those.
    static func localizedValue(_ map: [String: String]?, language: String) -> String? {
        guard let map, !map.isEmpty else { return nil }
        let normalized = map.reduce(into: [String: String]()) { result, entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result[Self.normalize(entry.key)] = value }
        }
        let wanted = normalize(language)
        if let value = normalized[wanted] { return value }
        let primary = String(wanted.split(separator: "-").first ?? "")
        if let value = normalized[primary] { return value }
        return normalized["en"]
    }

    static func normalize(_ tag: String) -> String {
        tag.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func fontDesign(from remote: String) -> SupportAppearance.FontDesign? {
        switch remote {
        case "default": return .default
        case "rounded": return .rounded
        case "serif": return .serif
        case "mono", "monospaced": return .monospaced
        default: return nil
        }
    }
}

extension UIColor {
    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
    convenience init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        if string.count == 3 { string = string.map { "\($0)\($0)" }.joined() }
        guard string.count == 6 || string.count == 8, let value = UInt64(string, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if string.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
