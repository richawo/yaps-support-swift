import SwiftUI
import UIKit

/// The resolved appearance in SwiftUI terms, passed through the environment.
///
/// Craft follows the Design for AI `mobile-chat`, `mobile-attachment-tray` and `chat-thread`
/// briefs. Every hue comes from the host's appearance: one accent, from which the bubble stops,
/// ink, glow and soft fill are derived, so a single colour rebrands the chat. Everything else is
/// the system's neutral family.
struct ChatTheme {
    // Host colours
    var accent: Color
    var background: Color
    var incomingBackground: Color
    var incomingForeground: Color

    // Derived accent tokens
    var accentTop: Color
    var accentBottom: Color
    /// Text and symbols on the accent: the host's `onAccent`, or black/white chosen by luminance.
    var accentInk: Color
    var accentGlow: Color
    var accentSoft: Color

    // Derived neutrals
    var incomingTop: Color
    var incomingBottom: Color
    var hairline: Color

    // Shape and type
    var radius: CGFloat
    var design: Font.Design
    var fadesOlderMessages: Bool

    /// Corner radii for grouped bubbles: outer 20, joined 7, tail 10 at the round style.
    var joinedRadius: CGFloat { min(7, radius) }
    var tailRadius: CGFloat { min(10, radius) }

    init(_ resolved: ResolvedAppearance) {
        let accent = resolved.accent.color
        self.accent = accent
        background = resolved.background.color
        incomingBackground = resolved.incomingBackground.color
        incomingForeground = resolved.incomingForeground.color

        accentTop = Self.derive(accent) { $0.mixed(with: .white, amount: 0.3) }
        accentBottom = Self.derive(accent) { $0.mixed(with: .black, amount: 0.07) }
        if case .standard = resolved.onAccent {
            accentInk = Self.derive(accent) { $0.isLight ? UIColor(white: 0.04, alpha: 1) : .white }
        } else {
            accentInk = resolved.onAccent.color
        }
        accentGlow = accent.opacity(0.4)
        accentSoft = accent.opacity(0.12)

        let incoming = resolved.incomingBackground.color
        incomingTop = Self.derive(incoming) { color in
            color.mixed(with: .white, amount: color.isLight ? 0.35 : 0.05)
        }
        incomingBottom = Self.derive(incoming) { $0.mixed(with: .black, amount: $0.isLight ? 0.015 : 0.04) }
        hairline = Color.primary.opacity(0.08)

        radius = resolved.bubbleRadius
        design = resolved.font
        fadesOlderMessages = resolved.fadesOlderMessages
    }

    var outgoingFill: LinearGradient {
        LinearGradient(colors: [accentTop, accent, accentBottom], startPoint: .top, endPoint: .bottom)
    }

    var incomingFill: LinearGradient {
        LinearGradient(colors: [incomingTop, incomingBottom], startPoint: .top, endPoint: .bottom)
    }

    func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: design).weight(weight)
    }

    /// Bubble text: 16 pt (callout) so it scales with Dynamic Type.
    var bubbleFont: Font { .system(.callout, design: design) }

    /// Small uppercase mono for metadata such as day dividers and card tags.
    static func mono(_ style: Font.TextStyle = .caption2, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }

    static let fallback = ChatTheme(AppearanceResolver.resolve(remote: nil, local: SupportAppearance(), language: "en", strings: { $0 }))

    private static func derive(_ color: Color, _ transform: @escaping @Sendable (UIColor) -> UIColor) -> Color {
        let base = UIColor(color)
        return Color(uiColor: UIColor { traits in transform(base.resolvedColor(with: traits)) })
    }
}

extension UIColor {
    /// Moves each channel `amount` of the way towards `target`.
    func mixed(with target: UIColor, amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1), target.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount, alpha: a1)
    }

    /// Perceived brightness above the midpoint (the brief's 0.299/0.587/0.114 weighting).
    var isLight: Bool {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return 0.299 * r + 0.587 * g + 0.114 * b > 150.0 / 255.0
    }
}

private struct ChatThemeKey: EnvironmentKey {
    static var defaultValue: ChatTheme { .fallback }
}

extension EnvironmentValues {
    var chatTheme: ChatTheme {
        get { self[ChatThemeKey.self] }
        set { self[ChatThemeKey.self] = newValue }
    }
}

/// Liquid Glass on iOS 26. Before that, a system material with the brief's glass recipe: a soft top
/// sheen and an inset rim (brighter on the top edge) instead of a flat translucent box.
struct GlassBackground<S: InsettableShape>: ViewModifier {
    var shape: S
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        } else {
            content
                .background {
                    shape.fill(.regularMaterial)
                        .overlay {
                            shape.fill(LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center))
                        }
                        .overlay {
                            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
                        }
                        .overlay { shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5) }
                        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                }
        }
    }
}

extension View {
    func glassBackground<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(GlassBackground(shape: shape, interactive: interactive))
    }
}

/// Presses to `scale` within a frame and springs back. Reduced motion dims instead of scaling.
struct SquishButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(configuration.isPressed ? .spring(response: 0.18, dampingFraction: 0.9)
                                               : .spring(response: 0.32, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SquishButtonStyle {
    static var squish: SquishButtonStyle { SquishButtonStyle() }
    static func squish(_ scale: CGFloat) -> SquishButtonStyle { SquishButtonStyle(scale: scale) }
}

/// Motion tokens from the briefs.
enum ChatMotion {
    /// `cubic-bezier(.22, 1, .36, 1)` at 520 ms: entrances and content arriving.
    static let arrive = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.52)
    /// Your bubble flying out of the composer: stiffness 240, damping 21, one soft settle.
    static let flight = Animation.interpolatingSpring(stiffness: 240, damping: 21)
    /// UI spring (500/40) for the composer height and small swaps.
    static let ui = Animation.interpolatingSpring(stiffness: 500, damping: 40)
    /// Pop for small badges (420/17): one overshoot.
    static let pop = Animation.interpolatingSpring(stiffness: 420, damping: 17)
    static let drawerOpen = Animation.easeOut(duration: 0.42)
    static let drawerFold = Animation.easeInOut(duration: 0.34)
    static let reduced = Animation.easeOut(duration: 0.15)
}

/// Small helpers for byte counts and dates in the user's language.
enum Formatters {
    static func fileSize(_ bytes: Int?, locale: Locale) -> String? {
        guard let bytes else { return nil }
        return Measurement(value: Double(bytes), unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .file).locale(locale))
    }

    static func time(_ date: Date, strings: Strings) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(strings.locale))
    }

    static func daySeparator(_ date: Date, strings: Strings, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = time(date, strings: strings)
        if calendar.isDateInToday(date) { return "\(strings("date.today")) · \(time)" }
        if calendar.isDateInYesterday(date) { return "\(strings("date.yesterday")) · \(time)" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(Date.FormatStyle().weekday(.wide).hour().minute().locale(strings.locale))
        }
        return date.formatted(Date.FormatStyle().day().month(.abbreviated).year().hour().minute().locale(strings.locale))
    }
}
