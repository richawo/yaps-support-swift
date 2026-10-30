import SwiftUI
import UIKit

/// Thread metrics from the `mobile-chat` brief.
enum ThreadMetrics {
    static let sideInset: CGFloat = 14
    /// Assistant gutter; the 26 pt avatar sits on the last bubble of a group.
    static let gutter: CGFloat = 34
    static let avatar: CGFloat = 26
    /// Your rows keep 60 pt clear on the leading side, theirs 34 pt on the trailing side.
    static let mineLeading: CGFloat = 60
    static let theirsTrailing: CGFloat = 34
    static let groupGap: CGFloat = 16
    static let bubbleGap: CGFloat = 3
}

/// A bubble with per-side grouped corners and, on the last bubble of a group, the brief's tail
/// (17 × 21, offset −6 pt), drawn as one path so the gradient runs through the joint seamlessly.
/// Drawn for the trailing side; mirrored for incoming bubbles and for right-to-left layouts.
struct BubbleShape: InsettableShape {
    var outer: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    var tail: Bool
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        let limit = min(rect.width, rect.height) / 2
        let tl = min(outer, limit), bl = min(outer, limit)
        let tr = min(top, limit), br = min(bottom, limit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        path.closeSubpath()
        guard tail, inset == 0, rect.height >= 21 else { return path }
        // M0 3h11c0 8 1.4 13.6 6 17.8-4.6.6-9.4-.4-12.6-3.2L0 17.6Z, placed 6 pt past the edge.
        let ox = rect.maxX + 6 - 17, oy = rect.maxY - 21
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x, y: oy + y) }
        path.move(to: p(0, 3))
        path.addLine(to: p(11, 3))
        path.addCurve(to: p(17, 20.8), control1: p(11, 11), control2: p(12.4, 16.6))
        path.addCurve(to: p(4.4, 17.6), control1: p(12.4, 21.4), control2: p(7.6, 20.4))
        path.addLine(to: p(0, 17.6))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> BubbleShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

struct MessageRowView: View {
    let item: RowLayout
    @ObservedObject var chat: ChatController
    @Binding var viewerImage: ImageViewerItem?

    @Environment(\.chatTheme) private var theme
    @Environment(\.supportStrings) private var strings
    @ScaledMetric(relativeTo: .callout) private var avatarSize: CGFloat = ThreadMetrics.avatar

    private var row: ChatRow { item.row }

    var body: some View {
        VStack(alignment: row.isOutgoing ? .trailing : .leading, spacing: 0) {
            if let separator = item.daySeparator {
                DayDivider(text: separator)
                    .padding(.top, ThreadMetrics.groupGap)
            }
            if item.showsAuthor, let name = row.authorName {
                Text(verbatim: name)
                    .font(theme.font(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, ThreadMetrics.gutter + 8)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .bottom, spacing: 0) {
                if row.isOutgoing {
                    Spacer(minLength: ThreadMetrics.mineLeading)
                } else {
                    avatar.frame(width: ThreadMetrics.gutter, alignment: .leading)
                }
                content
                if !row.isOutgoing {
                    Spacer(minLength: ThreadMetrics.theirsTrailing)
                }
            }
            if item.showsStatus {
                DeliveryStatusView(row: row, chat: chat)
                    .padding(.top, 5)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.top, item.isFirstInGroup ? ThreadMetrics.groupGap : ThreadMetrics.bubbleGap)
    }

    @ViewBuilder
    private var avatar: some View {
        if item.showsAvatar {
            AvatarView(url: row.avatarURL, name: row.authorName, isSystem: row.isSystem, size: avatarSize)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: avatarSize, height: 1)
        }
    }

    private var content: some View {
        VStack(alignment: row.isOutgoing ? .trailing : .leading, spacing: 4) {
            let images = row.attachments.filter(\.isImage)
            let files = row.attachments.filter { !$0.isImage }
            if !images.isEmpty {
                ImageGridView(images: images, isOutgoing: row.isOutgoing, viewerImage: $viewerImage, onFailedTap: retryIfFailed)
            }
            ForEach(files) { file in
                FileAttachmentView(attachment: file, isOutgoing: row.isOutgoing)
            }
            if !row.text.isEmpty {
                bubble
            }
            if let card = row.card {
                CardView(card: card, action: { chat.openCard(row) }, copy: { chat.copyCode(row) })
                    .padding(.top, row.text.isEmpty ? 0 : 2)
            }
        }
        .opacity(contentOpacity)
        .contextMenu { contextMenu }
    }

    private var contentOpacity: Double {
        if isFailed { return 0.82 }
        return row.isOutgoing && item.isOlder && theme.fadesOlderMessages ? 0.72 : 1
    }

    private var shape: BubbleShape {
        BubbleShape(outer: theme.radius,
                    top: item.isFirstInGroup ? theme.radius : theme.joinedRadius,
                    bottom: item.isLastInGroup ? theme.tailRadius : theme.joinedRadius,
                    tail: item.isLastInGroup && row.card == nil)
    }

    private var bubble: some View {
        Text(verbatim: row.text)
            .font(theme.bubbleFont)
            .tracking(-0.2)
            .lineSpacing(1)
            .foregroundStyle(row.isOutgoing ? theme.accentInk : theme.incomingForeground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 10)
            .background { bubbleBackground }
            .contentShape(shape)
            .onTapGesture { retryIfFailed() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(isFailed ? Text(verbatim: strings("status.tapToRetry")) : Text(verbatim: ""))
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        let mirrored = !row.isOutgoing
        Group {
            if row.isOutgoing {
                shape.fill(theme.outgoingFill)
                    .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.5), .clear],
                                                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.2)), lineWidth: 1))
                    .shadow(color: theme.accentGlow.opacity(0.7), radius: 9, y: 6)
            } else {
                shape.fill(theme.incomingFill)
                    .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.07), .clear],
                                                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.2)), lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            }
        }
        .scaleEffect(x: mirrored ? -1 : 1, y: 1)
        .flipsForRightToLeftLayoutDirection(true)
    }

    private var isFailed: Bool {
        if case .failed = row.delivery { return true }
        return false
    }

    private func retryIfFailed() {
        guard isFailed, let clientId = row.clientId else { return }
        chat.retry(clientId: clientId)
    }

    private var accessibilityLabel: Text {
        let author = row.isOutgoing ? strings("a11y.you") : (row.authorName ?? strings("a11y.team"))
        return Text(verbatim: "\(author), \(Formatters.time(row.date, strings: strings)): \(row.text)")
    }

    @ViewBuilder
    private var contextMenu: some View {
        if !row.text.isEmpty {
            Button {
                UIPasteboard.general.string = row.text
            } label: {
                Label(strings("menu.copy"), systemImage: "doc.on.doc")
            }
        }
        if isFailed, let clientId = row.clientId {
            Button {
                chat.retry(clientId: clientId)
            } label: {
                Label(strings("status.retry"), systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                chat.discard(clientId: clientId)
            } label: {
                Label(strings("status.delete"), systemImage: "trash")
            }
        }
    }
}

/// Small uppercase mono divider ("TODAY · 09:41").
struct DayDivider: View {
    let text: String

    var body: some View {
        Text(verbatim: text.uppercased())
            .font(ChatTheme.mono(.caption2))
            .tracking(1.4)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

struct AvatarView: View {
    let url: URL?
    let name: String?
    let isSystem: Bool
    let size: CGFloat
    @Environment(\.chatTheme) private var theme

    var body: some View {
        ZStack {
            Circle().fill(theme.incomingFill)
            if let url {
                RemoteImageView(source: .url(url), contentMode: .fill)
                    .clipShape(Circle())
            } else if let initial = name?.first {
                Text(String(initial).uppercased())
                    .font(.system(size: size * 0.46, weight: .bold, design: theme.design))
                    .foregroundStyle(theme.incomingForeground.opacity(0.85))
            } else {
                Image(systemName: isSystem ? "app.fill" : "person.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(theme.incomingForeground.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

/// The meta line under your last bubble: 11.5 pt, tabular, faint. Failures stay neutral, with an
/// icon, the reason and a Retry pill instead of a red tint.
struct DeliveryStatusView: View {
    let row: ChatRow
    @ObservedObject var chat: ChatController
    @Environment(\.chatTheme) private var theme
    @Environment(\.supportStrings) private var strings

    var body: some View {
        Group {
            switch row.delivery {
            case .none:
                EmptyView()
            case .sending(let progress):
                if let progress, progress < 1 {
                    HStack(spacing: 6) {
                        ProgressRing(progress: progress)
                        Text(verbatim: strings.format("status.uploading", Int(progress * 100)))
                    }
                } else {
                    Text(verbatim: strings("status.sending"))
                }
            case .sent:
                Text(verbatim: "\(strings("status.sent")) \(Formatters.time(row.date, strings: strings))")
            case .read:
                HStack(spacing: 3) {
                    Image(systemName: "checkmark").imageScale(.small)
                    Text(verbatim: strings("status.read"))
                }
            case .failed:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.primary)
                    Text(verbatim: strings("status.failed"))
                        .foregroundStyle(.primary)
                    Button {
                        if let clientId = row.clientId { chat.retry(clientId: clientId) }
                    } label: {
                        Text(verbatim: strings("status.retry"))
                            .font(theme.font(.caption, weight: .bold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 28)
                            .glassBackground(in: Capsule(), interactive: true)
                            .contentShape(Capsule())
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.squish(0.94))
                }
            }
        }
        .font(theme.font(.caption2, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: row.delivery)
    }
}

struct ProgressRing: View {
    let progress: Double
    @Environment(\.chatTheme) private var theme

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.02, progress))
                .stroke(theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// Cards sit on their own surface under the bubble. Each kind has its own view.
struct CardView: View {
    let card: ChatRow.CardContent
    let action: () -> Void
    /// Code cards: copies the code and reports whether it was copied.
    var copy: () -> Bool = { false }

    var body: some View {
        switch card {
        case .review, .offer:
            ActionCardView(card: card, action: action)
        case .app(let promo):
            AppPromoCardView(promo: promo, action: action)
        case .code(let code):
            CodeCardView(code: code, redeem: action, copy: copy)
        }
    }
}

/// The mono tag row at the top of every card ("APP STORE", "OFFER").
struct CardTag: View {
    let icon: String
    let text: String
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(verbatim: text.uppercased())
                // Monospacing and letter spacing break Arabic joining, so right-to-left tags use the
                // proportional face.
                .font(layoutDirection == .rightToLeft ? .system(.caption2).weight(.semibold) : ChatTheme.mono(.caption2))
                .tracking(layoutDirection == .rightToLeft ? 0 : 1)
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// The full-width 42 pt neutral action every card ends with.
struct CardActionLabel: View {
    let text: String
    var symbol: String?
    var enabled: Bool = true
    @Environment(\.chatTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .flipsForRightToLeftLayoutDirection(true)
            }
        }
        .font(theme.font(.subheadline, weight: .semibold))
        .foregroundStyle(enabled ? theme.incomingForeground : Color.secondary)
        .frame(maxWidth: .infinity, minHeight: 42)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(enabled ? 0.07 : 0.035))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(enabled ? 0.07 : 0.05), lineWidth: 1))
        )
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

/// The card surface: incoming fill, one lit top-trailing corner, a hairline rim and a soft shadow.
struct CardSurface: ViewModifier {
    @Environment(\.chatTheme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(minWidth: 240, maxWidth: 320, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: max(theme.radius, 12), style: .continuous)
                shape.fill(theme.incomingFill)
                    .overlay {
                        // A 7 % lit corner, top-trailing: the card's one light source.
                        shape.fill(RadialGradient(colors: [Color.white.opacity(0.07), .clear], center: UnitPoint(x: 0.92, y: 0),
                                                  startRadius: 0, endRadius: 180))
                    }
                    .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.08), Color.primary.opacity(0.06)],
                                                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: .black.opacity(0.1), radius: 14, y: 8)
            }
            .accessibilityElement(children: .contain)
    }
}

extension View {
    func cardSurface() -> some View { modifier(CardSurface()) }
}

/// Review and offer cards (radius 20, padding 14): a mono tag row, the title, and a full-width
/// 42 pt neutral action. Unavailable offers grey out.
struct ActionCardView: View {
    let card: ChatRow.CardContent
    let action: () -> Void
    @Environment(\.chatTheme) private var theme
    @Environment(\.supportStrings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTag(icon: icon, text: tag)

            if let title, !title.isEmpty {
                Text(verbatim: title)
                    .font(theme.font(.headline, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(theme.incomingForeground)
                    .padding(.top, 10)
            }

            Button(action: action) {
                CardActionLabel(text: available ? label : strings("card.unavailable"),
                                symbol: available ? (card.isReview ? "arrow.up.right" : "chevron.right") : nil,
                                enabled: available)
            }
            .buttonStyle(.squish)
            .disabled(!available)
            .padding(.top, 14)
            .accessibilityLabel(Text(verbatim: available ? label : "\(label), \(strings("card.unavailable"))"))
        }
        .cardSurface()
    }

    private var available: Bool {
        switch card {
        case .offer(_, _, _, let available): return available
        default: return true
        }
    }

    private var icon: String {
        card.isReview ? "star.fill" : "tag.fill"
    }

    private var tag: String {
        card.isReview ? "App Store" : strings("card.offerTag")
    }

    private var title: String? {
        if case .offer(_, _, let title, _) = card { return title }
        return nil
    }

    private var label: String {
        switch card {
        case .review(_, let label): return label?.nonEmpty ?? strings("card.review")
        case .offer(_, let label, _, _): return label?.nonEmpty ?? strings("card.offer")
        default: return ""
        }
    }
}

extension ChatRow.CardContent {
    var isReview: Bool {
        if case .review = self { return true }
        return false
    }
}

/// Three dots breathing in sequence inside a tailed incoming bubble that pops in from its
/// bottom-leading corner (spring 320/26). The view's single ambient motion.
struct TypingIndicatorView: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.supportStrings) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Color.clear.frame(width: ThreadMetrics.gutter, height: 1)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.25) / 1.25
                let wave = (1 - cos(cycle * 2 * .pi)) / 2
                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        let level = reduceMotion ? 0.5 : Self.level(wave: wave, phase: cycle, index: index)
                        Circle()
                            .fill(theme.incomingForeground)
                            .frame(width: 7.5, height: 7.5)
                            .opacity(0.3 + 0.7 * level)
                            .scaleEffect(0.86 + 0.24 * level)
                    }
                }
                .frame(height: 22)
                .padding(.horizontal, 3)
            }
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 10)
            .background {
                let shape = BubbleShape(outer: theme.radius, top: theme.radius, bottom: theme.tailRadius, tail: true)
                shape.fill(theme.incomingFill)
                    .scaleEffect(x: -1, y: 1)
                    .flipsForRightToLeftLayoutDirection(true)
            }
            Spacer(minLength: ThreadMetrics.theirsTrailing)
        }
        .padding(.top, ThreadMetrics.groupGap)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: strings("typing.agent")))
    }

    /// Each dot peaks a little after the one before it.
    private static func level(wave: Double, phase: Double, index: Int) -> Double {
        let start = 0.05 + Double(index) * 0.18
        let distance = phase - start
        guard distance >= 0, distance <= 0.4 else { return 0 }
        return sin(distance / 0.4 * .pi)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
