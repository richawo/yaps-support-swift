import Foundation

/// One bubble in the transcript, built from a server message or a pending outbox entry.
struct ChatRow: Identifiable, Equatable {
    enum Delivery: Equatable {
        case none
        case sending(progress: Double?)
        case sent
        case read
        case failed(code: String?)
    }

    enum CardContent: Equatable {
        case review(url: URL, label: String?)
        case offer(paywallId: String, label: String?, title: String?, available: Bool)
        case app(AppPromo)
        case code(PromoCode)
    }

    /// Another app from the same organisation (§5 App promo card).
    struct AppPromo: Equatable {
        enum State: Equatable {
            /// Shows the "Get it" button.
            case available
            /// The customer already uses the app: "You already have it", no button.
            case installed
        }

        var title: String?
        var body: String?
        var iconURL: URL?
        /// Numeric App Store ID for the in-app store sheet.
        var appStoreId: String?
        /// Store page for this device; the fallback when the sheet can't open.
        var url: URL?
        var label: String?
        var state: State
    }

    /// A discount or promo code (§5 Code card).
    struct PromoCode: Equatable {
        enum Platform: String, Equatable {
            case ios, android, web, any
        }

        enum State: Equatable {
            /// Copy, plus Redeem when there's a redeem URL.
            case available
            /// Redeemable elsewhere: Copy plus a "Redeem on …" hint.
            case otherPlatform
            /// Past `expiresAt`: struck through, no buttons.
            case expired
        }

        var code: String
        var title: String?
        var body: String?
        var label: String?
        var redeemURL: URL?
        var platform: Platform
        var expiresAt: Date?
        var state: State
    }

    enum AttachmentContent: Equatable, Identifiable {
        case remoteImage(id: String, thumbnail: URL?, full: URL, width: Int?, height: Int?)
        case remoteFile(id: String, url: URL, filename: String, size: Int?)
        case localImage(id: String, file: URL, width: Int?, height: Int?)
        case localFile(id: String, file: URL, filename: String, size: Int?)

        var id: String {
            switch self {
            case .remoteImage(let id, _, _, _, _), .remoteFile(let id, _, _, _),
                 .localImage(let id, _, _, _), .localFile(let id, _, _, _):
                return id
            }
        }

        var isImage: Bool {
            switch self {
            case .remoteImage, .localImage: return true
            default: return false
            }
        }

        var aspectRatio: CGFloat? {
            switch self {
            case .remoteImage(_, _, _, let w?, let h?), .localImage(_, _, let w?, let h?):
                return h > 0 ? CGFloat(w) / CGFloat(h) : nil
            default:
                return nil
            }
        }
    }

    var id: String
    var messageId: String?
    var clientId: String?
    var seq: Int?
    var isOutgoing: Bool
    var isSystem: Bool
    var authorName: String?
    var avatarURL: URL?
    var text: String
    var attachments: [AttachmentContent]
    var card: CardContent?
    var date: Date
    var delivery: Delivery
}

enum ChatPresentation {
    /// PROTOCOL §5: show `translation.text` when the translation is in the customer's language,
    /// otherwise the original `text`.
    static func displayText(for message: Message, customerLanguage: String) -> String {
        guard let translation = message.translation, !translation.text.isEmpty else { return message.text }
        return languagesMatch(translation.language, customerLanguage) ? translation.text : message.text
    }

    static func languagesMatch(_ a: String, _ b: String) -> Bool {
        let lhs = AppearanceResolver.normalize(a)
        let rhs = AppearanceResolver.normalize(b)
        if lhs == rhs { return true }
        let lp = lhs.split(separator: "-").first
        let rp = rhs.split(separator: "-").first
        // Chinese scripts are different written languages; match them exactly.
        if lp == "zh" || rp == "zh" { return false }
        return lp != nil && lp == rp
    }

    struct Context {
        var customerLanguage: String
        var agentReadSeq: Int
        var showNames: Bool = true
        var showPhotos: Bool = true
        var uploadProgress: [String: Double] = [:]
        var isPaywallAvailable: (String) -> Bool
        var fileURL: (String) -> URL
        /// Decides whether code cards have expired.
        var now: Date = Date()
    }

    static func card(for message: Message, context: Context) -> ChatRow.CardContent? {
        guard let card = message.card else { return nil }
        switch card.known {
        case .review:
            guard let string = card.url, let url = URL(string: string) else { return nil }
            return .review(url: url, label: card.buttonLabel)
        case .offer:
            guard let paywallId = card.paywallId else { return nil }
            let available = card.available != false && context.isPaywallAvailable(paywallId)
            return .offer(paywallId: paywallId, label: card.buttonLabel, title: card.title, available: available)
        case .app:
            return appPromo(for: card).map(ChatRow.CardContent.app)
        case .code:
            return promoCode(for: card, now: context.now).map(ChatRow.CardContent.code)
        case .unknown:
            return nil // rendered as plain text (§9)
        }
    }

    /// `installed` wins; otherwise the card needs `available` and somewhere to go (a store ID or
    /// URL). Anything else renders as plain text.
    static func appPromo(for card: Card) -> ChatRow.AppPromo? {
        let appStoreId = card.appStoreId.flatMap { id in
            !id.isEmpty && id.allSatisfy({ ("0"..."9").contains($0) }) ? id : nil
        }
        let url = card.url.flatMap(URL.init(string:))
        let state: ChatRow.AppPromo.State
        if card.installed == true {
            state = .installed
        } else if card.available != false, appStoreId != nil || url != nil {
            state = .available
        } else {
            return nil
        }
        return ChatRow.AppPromo(title: card.title?.nonEmpty, body: card.body?.nonEmpty,
                                iconURL: card.iconUrl.flatMap(URL.init(string:)), appStoreId: appStoreId, url: url,
                                label: card.buttonLabel?.nonEmpty, state: state)
    }

    /// Expiry wins over everything; `available: false` means another platform (the server leaves
    /// out `url` then). A card without a code renders as plain text.
    static func promoCode(for card: Card, now: Date) -> ChatRow.PromoCode? {
        guard let code = card.code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else { return nil }
        let expiresAt = card.expiryDate
        let platform = card.platform.flatMap(ChatRow.PromoCode.Platform.init(rawValue:)) ?? .any
        let state: ChatRow.PromoCode.State
        if let expiresAt, expiresAt <= now {
            state = .expired
        } else if card.available == false {
            state = .otherPlatform
        } else {
            state = .available
        }
        let redeemURL = state == .available ? card.url.flatMap(URL.init(string:)) : nil
        return ChatRow.PromoCode(code: code, title: card.title?.nonEmpty, body: card.body?.nonEmpty,
                                 label: card.buttonLabel?.nonEmpty, redeemURL: redeemURL, platform: platform,
                                 expiresAt: expiresAt, state: state)
    }

    /// The next moment a visible code card expires, so the thread can redraw it then.
    static func nextExpiry(in messages: [Message], after now: Date) -> Date? {
        messages.compactMap { message -> Date? in
            guard message.card?.known == .code, let date = message.card?.expiryDate, date > now else { return nil }
            return date
        }.min()
    }

    static func attachments(for message: Message) -> [ChatRow.AttachmentContent] {
        message.attachments.compactMap { attachment in
            guard let url = URL(string: attachment.url) else { return nil }
            switch attachment.kind {
            case .image:
                return .remoteImage(id: attachment.id, thumbnail: attachment.thumbnailUrl.flatMap(URL.init(string:)),
                                    full: url, width: attachment.width, height: attachment.height)
            default:
                return .remoteFile(id: attachment.id, url: url, filename: attachment.filename ?? "file", size: attachment.size)
            }
        }
    }

    static func row(for message: Message, context: Context) -> ChatRow {
        let outgoing = message.isFromCustomer
        var delivery: ChatRow.Delivery = .none
        if outgoing { delivery = message.seq <= context.agentReadSeq ? .read : .sent }
        let card = card(for: message, context: context)
        var text = displayText(for: message, customerLanguage: context.customerLanguage)
        if message.card != nil, card == nil, text.isEmpty, let label = message.card?.title ?? message.card?.buttonLabel {
            text = label
        }
        return ChatRow(
            id: message.clientId.map { "c:\($0)" } ?? "m:\(message.id)",
            messageId: message.id,
            clientId: message.clientId,
            seq: message.seq,
            isOutgoing: outgoing,
            isSystem: message.author.type == .system,
            authorName: outgoing || !context.showNames ? nil : message.author.name,
            avatarURL: outgoing || !context.showPhotos ? nil : message.author.avatarUrl.flatMap(URL.init(string:)),
            text: text,
            attachments: attachments(for: message),
            card: card,
            date: message.createdAt,
            delivery: delivery
        )
    }

    static func row(for pending: PendingMessage, context: Context) -> ChatRow {
        let delivery: ChatRow.Delivery
        switch pending.state {
        case .failed: delivery = .failed(code: pending.lastErrorCode)
        case .sending: delivery = .sending(progress: context.uploadProgress[pending.clientId])
        case .queued: delivery = .sending(progress: nil)
        }
        let attachments: [ChatRow.AttachmentContent] = pending.attachments.enumerated().map { index, attachment in
            let id = "\(pending.clientId)-\(index)"
            let file = context.fileURL(attachment.localFile)
            switch attachment.kind {
            case .image: return .localImage(id: id, file: file, width: attachment.width, height: attachment.height)
            default: return .localFile(id: id, file: file, filename: attachment.filename ?? "file", size: attachment.size)
            }
        }
        return ChatRow(id: "c:\(pending.clientId)", messageId: nil, clientId: pending.clientId, seq: nil, isOutgoing: true,
                       isSystem: false, authorName: nil, avatarURL: nil, text: pending.text, attachments: attachments,
                       card: nil, date: pending.createdAt, delivery: delivery)
    }

    /// Server messages in seq order, then pending messages in the order they were sent. Pending
    /// entries whose client ID the server already returned are hidden (dedupe).
    static func rows(messages: [Message], outbox: [PendingMessage], context: Context) -> [ChatRow] {
        let confirmed = Set(messages.compactMap(\.clientId))
        var rows = messages.filter(\.isDisplayable).map { row(for: $0, context: context) }
        rows += outbox.filter { !confirmed.contains($0.clientId) }.map { row(for: $0, context: context) }
        return rows
    }
}
