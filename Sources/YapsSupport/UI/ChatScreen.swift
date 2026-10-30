import SwiftUI
import UIKit

/// Root of the chat: snapshots the appearance on open (remote changes apply on the next open) and
/// supplies theme, strings, locale and layout direction.
struct ChatRoot: View {
    let engine: SupportEngine
    let chrome: SupportChatView.Chrome
    let onClose: (() -> Void)?

    @State private var resolved: ResolvedAppearance
    @State private var strings: Strings

    init(engine: SupportEngine, chrome: SupportChatView.Chrome, onClose: (() -> Void)?) {
        self.engine = engine
        self.chrome = chrome
        self.onClose = onClose
        _resolved = State(initialValue: engine.resolvedAppearance())
        _strings = State(initialValue: engine.strings)
    }

    var body: some View {
        content
            .environment(\.chatTheme, ChatTheme(resolved))
            .environment(\.supportStrings, strings)
            .environment(\.locale, strings.locale)
            .environment(\.layoutDirection, strings.layoutDirection)
            .tint(resolved.accent.color)
            .preferredColorScheme(resolved.preferredColorScheme)
    }

    @ViewBuilder
    private var content: some View {
        switch chrome {
        case .standalone:
            NavigationStack {
                ChatScreen(chat: engine.chat, resolved: resolved, onClose: onClose, showsCloseButton: resolved.showsCloseButton)
            }
        case .embedded:
            ChatScreen(chat: engine.chat, resolved: resolved, onClose: nil, showsCloseButton: false)
        }
    }
}

struct ChatScreen: View {
    @ObservedObject var chat: ChatController
    let resolved: ResolvedAppearance
    let onClose: (() -> Void)?
    let showsCloseButton: Bool

    @Environment(\.chatTheme) private var theme
    @Environment(\.supportStrings) private var strings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewerImage: ImageViewerItem?
    @State private var lastRowID: String?
    @State private var isAtBottom = true
    @State private var unseenReply = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    ForEach(layout) { item in
                        MessageRowView(item: item, chat: chat, viewerImage: $viewerImage)
                            .id(item.row.id)
                            .transition(transition(for: item.row))
                    }
                    if chat.agentTyping {
                        TypingIndicatorView()
                            .transition(typingTransition)
                    }
                    Color.clear
                        .frame(height: 12)
                        .id(Self.bottomID)
                        .onAppear {
                            isAtBottom = true
                            unseenReply = false
                        }
                        .onDisappear { isAtBottom = false }
                }
                .padding(.horizontal, ThreadMetrics.sideInset)
                .animation(reduceMotion ? ChatMotion.reduced : ChatMotion.arrive, value: chat.rows.map(\.id))
                .animation(reduceMotion ? ChatMotion.reduced : ChatMotion.pop, value: chat.agentTyping)
            }
            .scrollDismissesKeyboard(.interactively)
            .modifier(BottomAnchoredScroll())
            .onAppear {
                lastRowID = chat.rows.last?.id
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: chat.rows.last?.id) { newValue in
                guard newValue != lastRowID else { return }
                let firstLoad = lastRowID == nil
                lastRowID = newValue
                guard let last = chat.rows.last else { return }
                if firstLoad {
                    // The first page arrived after the view appeared: open at the newest message.
                    isAtBottom = true
                    scrollToBottom(proxy, animated: false)
                    return
                }
                // Stay pinned to the conversation unless the reader scrolled up; your own sends
                // always bring you back.
                if last.isOutgoing || isAtBottom {
                    scrollToBottom(proxy, animated: true)
                } else {
                    unseenReply = true
                }
                if !last.isOutgoing { announce(last) }
            }
            .onChange(of: chat.agentTyping) { typing in
                if typing && isAtBottom { scrollToBottom(proxy, animated: true) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if !isAtBottom && !chat.rows.isEmpty {
                        JumpPill(unseen: unseenReply) {
                            unseenReply = false
                            scrollToBottom(proxy, animated: true)
                        }
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    } else {
                        ConnectionBannerView(connection: chat.connection)
                    }
                    ComposerContainer(chat: chat, scrollToBottom: { scrollToBottom(proxy, animated: true) })
                }
                .padding(.top, 6)
                .background(alignment: .top) {
                    // A 32 pt fade from the chat background so the thread recedes under the glass.
                    LinearGradient(stops: [.init(color: theme.background.opacity(0), location: 0),
                                           .init(color: theme.background.opacity(0.92), location: 0.45),
                                           .init(color: theme.background, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .padding(.top, -26)
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                }
                .animation(reduceMotion ? ChatMotion.reduced : .easeOut(duration: 0.24), value: isAtBottom)
            }
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(resolved.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton && (onClose != nil || isPresented) {
                ToolbarItem(placement: .primaryAction) {
                    CloseButton(icon: resolved.closeIcon) {
                        if let onClose { onClose() } else { dismiss() }
                    }
                }
            }
        }
        .onAppear { chat.chatDidAppear() }
        .onDisappear { chat.chatDidDisappear() }
        .fullScreenCover(item: $viewerImage) { item in
            ImageViewer(item: item)
                .environment(\.supportStrings, strings)
        }
    }

    private static let bottomID = "yaps-support-bottom"

    private var layout: [RowLayout] { RowLayout.build(chat.rows, strings: strings) }

    /// Your new bubble flies up out of the composer (74 pt lower, 18 pt in, scale 0.86 from its
    /// bottom-trailing corner) on a 240/21 spring; replies rise 12 pt from 0.97 and fade in.
    private func transition(for row: ChatRow) -> AnyTransition {
        if reduceMotion { return .opacity.animation(ChatMotion.reduced) }
        if row.isOutgoing, case .sending = row.delivery {
            return .asymmetric(insertion: .modifier(active: Flight(progress: 0), identity: Flight(progress: 1)).animation(ChatMotion.flight),
                               removal: .opacity)
        }
        return .asymmetric(insertion: .modifier(active: Arrive(progress: 0), identity: Arrive(progress: 1)).animation(ChatMotion.arrive),
                           removal: .opacity)
    }

    private var typingTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .scale(scale: 0.8, anchor: .bottomLeading).combined(with: .opacity)
    }

    @ViewBuilder
    private var header: some View {
        if chat.hasMore {
            LoadEarlierView(chat: chat)
        } else {
            WelcomeHeaderView(resolved: resolved)
        }
        if chat.loadState == .loading && chat.rows.isEmpty {
            ProgressView()
                .padding(.vertical, 24)
        } else if chat.loadState == .failed && chat.rows.isEmpty {
            VStack(spacing: 8) {
                Text(verbatim: strings("history.loadFailed"))
                    .font(theme.font(.subheadline))
                    .foregroundStyle(.secondary)
                Button {
                    chat.refreshNow()
                } label: {
                    Text(verbatim: strings("history.tryAgain"))
                        .font(theme.font(.subheadline, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .glassBackground(in: Capsule(), interactive: true)
                }
                .buttonStyle(.squish)
            }
            .padding(.vertical, 16)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated && !reduceMotion {
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private func announce(_ row: ChatRow) {
        guard UIAccessibility.isVoiceOverRunning, !row.text.isEmpty else { return }
        let author = row.authorName ?? strings("a11y.team")
        UIAccessibility.post(notification: .announcement, argument: "\(author): \(row.text)")
    }
}

private struct Flight: ViewModifier {
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.86 + 0.14 * progress, anchor: .bottomTrailing)
            .offset(x: -18 * (1 - progress), y: 74 * (1 - progress))
            .opacity(Double(min(1, 0.2 + progress)))
    }
}

private struct Arrive: ViewModifier {
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.97 + 0.03 * progress, anchor: .bottomLeading)
            .offset(y: 12 * (1 - progress))
            .opacity(Double(progress))
    }
}

/// A 36 pt glass pill that appears when you've scrolled up: "Latest", or "New reply" with an
/// accent dot when one arrived meanwhile.
private struct JumpPill: View {
    let unseen: Bool
    let action: () -> Void
    @Environment(\.chatTheme) private var theme
    @Environment(\.supportStrings) private var strings

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if unseen {
                    Circle().fill(theme.accent).frame(width: 6, height: 6)
                }
                Text(verbatim: strings(unseen ? "jump.newReply" : "jump.latest"))
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .font(theme.font(.footnote, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .glassBackground(in: Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.squish(0.95))
        .frame(minHeight: 44)
        .accessibilityLabel(Text(verbatim: strings(unseen ? "jump.newReply" : "jump.latest")))
    }
}


/// Starts scrolled to the newest message on iOS 17+.
private struct BottomAnchoredScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
    }
}

/// Precomputed grouping for a row: day separators, author headers, avatars and status lines.
struct RowLayout: Identifiable {
    var row: ChatRow
    var daySeparator: String?
    var showsAuthor: Bool
    var showsAvatar: Bool
    var isFirstInGroup: Bool
    var isLastInGroup: Bool
    var showsStatus: Bool
    var isOlder: Bool

    var id: String { row.id }

    static func build(_ rows: [ChatRow], strings: Strings) -> [RowLayout] {
        let lastOutgoingIndex = rows.lastIndex { $0.isOutgoing }
        var result: [RowLayout] = []
        result.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            let previous = index > 0 ? rows[index - 1] : nil
            let next = index + 1 < rows.count ? rows[index + 1] : nil
            let gapBefore = previous.map { row.date.timeIntervalSince($0.date) > 3600 } ?? true
            let newDay = previous.map { !Calendar.current.isDate($0.date, inSameDayAs: row.date) } ?? true
            let separator = (gapBefore || newDay) ? Formatters.daySeparator(row.date, strings: strings) : nil
            let sameAuthorAsPrevious = previous.map { sameGroup($0, row) } ?? false
            let sameAuthorAsNext = next.map { sameGroup(row, $0) && !(($0.date.timeIntervalSince(row.date) > 3600)) } ?? false
            let first = separator != nil || !sameAuthorAsPrevious
            let last = !sameAuthorAsNext
            var showsStatus = false
            switch row.delivery {
            case .failed, .sending: showsStatus = true
            case .sent, .read: showsStatus = index == lastOutgoingIndex
            case .none: showsStatus = false
            }
            let isOlder = row.isOutgoing && lastOutgoingIndex.map { index < $0 } ?? false
            result.append(RowLayout(row: row, daySeparator: separator,
                                    showsAuthor: !row.isOutgoing && first && row.authorName != nil,
                                    showsAvatar: !row.isOutgoing && last,
                                    isFirstInGroup: first, isLastInGroup: last, showsStatus: showsStatus, isOlder: isOlder))
        }
        return result
    }

    private static func sameGroup(_ a: ChatRow, _ b: ChatRow) -> Bool {
        guard a.isOutgoing == b.isOutgoing else { return false }
        if a.isOutgoing { return b.date.timeIntervalSince(a.date) < 300 }
        return a.authorName == b.authorName && a.isSystem == b.isSystem && b.date.timeIntervalSince(a.date) < 300
    }
}

private struct LoadEarlierView: View {
    @ObservedObject var chat: ChatController
    @Environment(\.supportStrings) private var strings
    @Environment(\.chatTheme) private var theme

    var body: some View {
        Group {
            if chat.isLoadingEarlier {
                ProgressView()
            } else {
                Button(strings("history.loadEarlier")) {
                    Task { await chat.loadEarlier() }
                }
                .font(theme.font(.footnote, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .onAppear {
            // Scrolling to the top loads the previous page automatically.
            Task { await chat.loadEarlier() }
        }
    }
}

struct CloseButton: View {
    let icon: SupportAppearance.CloseIcon
    let action: () -> Void
    @Environment(\.supportStrings) private var strings

    var body: some View {
        Button(action: action) {
            if #available(iOS 26.0, *) {
                Image(systemName: icon.rawValue)
            } else {
                Image(systemName: icon.rawValue)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
            }
        }
        .accessibilityLabel(Text(verbatim: strings("a11y.close")))
    }
}


/// Welcome block above the first message: the icon on a soft accent fill, a tight display
/// heading (−0.03 em) and one muted line.
struct WelcomeHeaderView: View {
    let resolved: ResolvedAppearance
    @Environment(\.chatTheme) private var theme
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            icon
                .padding(.bottom, 16)
            Text(verbatim: resolved.welcomeTitle)
                .font(theme.font(.title2, weight: .bold))
                .tracking(-0.7)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: resolved.welcomeText)
                .font(theme.font(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 300)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch resolved.welcomeIcon {
        case .hidden:
            EmptyView()
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: iconSize * 0.4, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: iconSize, height: iconSize)
                .background(Circle().fill(theme.accentSoft))
                .overlay(Circle().strokeBorder(theme.accent.opacity(0.18), lineWidth: 0.5))
                .accessibilityHidden(true)
        case .image(let image):
            image.resizable().scaledToFill()
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
                .accessibilityHidden(true)
        case .url(let url):
            RemoteImageView(source: .url(url), contentMode: .fill)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
                .accessibilityHidden(true)
        }
    }
}

/// Connection status as a 36 pt glass pill above the composer. Neutral ink only; hue lives in the
/// accent.
struct ConnectionBannerView: View {
    let connection: ChatController.Connection
    @Environment(\.supportStrings) private var strings
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let content {
                HStack(spacing: 6) {
                    if connection == .connecting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: content.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: strings(content.key))
                }
                .font(theme.font(.footnote, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassBackground(in: Capsule())
                .transition(.opacity.combined(with: .offset(y: 6)))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(reduceMotion ? ChatMotion.reduced : .easeOut(duration: 0.25), value: connection)
    }

    private var content: (icon: String, key: String)? {
        switch connection {
        case .hidden: return nil
        case .offline: return ("wifi.slash", "connection.offline")
        case .connecting: return ("arrow.triangle.2.circlepath", "connection.connecting")
        case .connected: return ("checkmark", "connection.connected")
        case .polling: return ("pause.fill", "connection.polling")
        }
    }
}
