import SwiftUI
import UIKit

/// Another app from the same team: its icon (rounded like a home-screen icon), name and pitch,
/// then "Get it", or "You already have it" when the customer already uses it.
struct AppPromoCardView: View {
    let promo: ChatRow.AppPromo
    let action: () -> Void

    @Environment(\.chatTheme) private var theme
    @Environment(\.supportStrings) private var strings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTag(icon: "app.badge.fill", text: "App Store")

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                AppIconView(url: promo.iconURL, size: min(iconSize, 84))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if let title = promo.title {
                        Text(verbatim: title)
                            .font(theme.font(.headline, weight: .bold))
                            .tracking(-0.3)
                            .foregroundStyle(theme.incomingForeground)
                    }
                    if let body = promo.body {
                        Text(verbatim: body)
                            .font(theme.font(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
            .padding(.top, 12)

            Group {
                switch promo.state {
                case .available:
                    Button(action: action) {
                        CardActionLabel(text: label, symbol: "arrow.up.right")
                    }
                    .buttonStyle(.squish)
                    .accessibilityLabel(Text(verbatim: promo.title.map { "\(label), \($0)" } ?? label))
                case .installed:
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(verbatim: strings("card.installed"))
                    }
                    .font(theme.font(.subheadline, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.primary.opacity(0.035)))
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 14)
        }
        .cardSurface()
    }

    private var label: String { promo.label ?? strings("card.getApp") }
}

/// A remote app icon in the home-screen squircle, with a neutral glyph while it loads or if it
/// can't.
struct AppIconView: View {
    let url: URL?
    let size: CGFloat

    @Environment(\.chatTheme) private var theme
    @State private var image: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                shape.fill(LinearGradient(colors: [Color.primary.opacity(0.06), Color.primary.opacity(0.12)],
                                          startPoint: .top, endPoint: .bottom))
                Image(systemName: "app.dashed")
                    .font(.system(size: size * 0.42, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .task(id: url) {
            guard let url else { return }
            if let cached = ImageCache.shared.cached(url) {
                image = cached
                return
            }
            let loaded = await ImageCache.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// A discount code in a dashed, monospaced, selectable box with Copy, then Redeem (when this
/// device can redeem it), a "Redeem on …" hint (when it can't), or "Expired".
struct CodeCardView: View {
    let code: ChatRow.PromoCode
    let redeem: () -> Void
    let copy: () -> Bool

    @Environment(\.chatTheme) private var theme
    @Environment(\.supportStrings) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    private var expired: Bool { code.state == .expired }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTag(icon: "ticket.fill", text: strings("card.codeTag"))

            if let title = code.title {
                Text(verbatim: title)
                    .font(theme.font(.headline, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(theme.incomingForeground)
                    .padding(.top, 10)
            }
            if let body = code.body {
                Text(verbatim: body)
                    .font(theme.font(.subheadline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }

            codeBox
                .padding(.top, 12)

            footer
                .padding(.top, 9)

            if code.state == .available, code.redeemURL != nil {
                Button(action: redeem) {
                    CardActionLabel(text: code.label ?? strings("card.redeem"), symbol: "arrow.up.right")
                }
                .buttonStyle(.squish)
                .padding(.top, 12)
            }
        }
        .cardSurface()
        .onDisappear { resetTask?.cancel() }
    }

    private var codeBox: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                codeText
                Spacer(minLength: 0)
                if !expired { copyButton }
            }
            VStack(alignment: .leading, spacing: 8) {
                codeText
                if !expired { copyButton }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, expired ? 14 : 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background {
            shape.fill(Color.primary.opacity(expired ? 0.03 : 0.05))
                .overlay(shape.strokeBorder(Color.primary.opacity(expired ? 0.12 : 0.2),
                                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }

    private var codeText: some View {
        Text(verbatim: code.code)
            .font(.system(.title3, design: .monospaced).weight(.semibold))
            .tracking(1.5)
            .strikethrough(expired)
            .foregroundStyle(expired ? Color.secondary : theme.incomingForeground)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityLabel(Self.accessibilityLabel(code: code.code, prefix: strings("card.codeTag"),
                                                        suffix: expired ? strings("card.expired") : nil))
    }

    private var copyButton: some View {
        Button {
            guard copy() else { return }
            confirmCopy()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .bold))
                    .contentTransition(.identity)
                Text(verbatim: strings(copied ? "card.copied" : "card.copy"))
            }
            .font(theme.font(.footnote, weight: .semibold))
            .foregroundStyle(copied ? theme.accentInk : theme.incomingForeground)
            .padding(.horizontal, 13)
            .frame(minHeight: 36)
            .background(Capsule().fill(copied ? AnyShapeStyle(theme.outgoingFill) : AnyShapeStyle(Color.primary.opacity(0.08))))
            .contentShape(Capsule())
            .frame(minHeight: 44)
        }
        .buttonStyle(.squish(0.94))
        .accessibilityLabel(Text(verbatim: strings(copied ? "card.copied" : "card.copy")))
    }

    @ViewBuilder
    private var footer: some View {
        switch code.state {
        case .available:
            if let expiresAt = code.expiresAt {
                note(icon: "clock", text: strings.format("card.expiresOn", Self.date(expiresAt, strings: strings)))
            }
        case .otherPlatform:
            VStack(alignment: .leading, spacing: 4) {
                if let hint = Self.hintKey(for: code.platform) {
                    note(icon: Self.hintIcon(for: code.platform), text: strings(hint))
                }
                if let expiresAt = code.expiresAt {
                    note(icon: "clock", text: strings.format("card.expiresOn", Self.date(expiresAt, strings: strings)))
                }
            }
        case .expired:
            note(icon: "clock.badge.xmark", text: strings("card.expired"))
        }
    }

    private func note(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(theme.font(.footnote, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func confirmCopy() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: strings("card.copied"))
        withAnimation(reduceMotion ? ChatMotion.reduced : ChatMotion.pop) { copied = true }
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? ChatMotion.reduced : .easeOut(duration: 0.25)) { copied = false }
        }
    }

    // MARK: - Helpers (internal for tests)

    /// The code spaced out and spelled, so VoiceOver reads it character by character
    /// ("S T U D E N T 2 0", never "student twenty").
    nonisolated static func spokenCode(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }

    static func accessibilityLabel(code: String, prefix: String, suffix: String?) -> Text {
        var label = Text(verbatim: "\(prefix), ") + Text(verbatim: spokenCode(code)).speechSpellsOutCharacters()
        if let suffix { label = label + Text(verbatim: ", \(suffix)") }
        return label
    }

    /// The "Redeem on …" hint for a code redeemable on another platform.
    nonisolated static func hintKey(for platform: ChatRow.PromoCode.Platform) -> String? {
        switch platform {
        case .ios: return "card.redeemOnIPhone"
        case .android: return "card.redeemOnAndroid"
        case .web: return "card.redeemOnWeb"
        case .any: return nil
        }
    }

    nonisolated static func hintIcon(for platform: ChatRow.PromoCode.Platform) -> String {
        switch platform {
        case .ios: return "iphone"
        case .android: return "candybarphone"
        case .web, .any: return "globe"
        }
    }

    static func date(_ date: Date, strings: Strings) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(strings.locale))
    }
}
