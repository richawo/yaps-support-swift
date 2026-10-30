import Foundation

// Wire types for PROTOCOL.md §5. Every type ignores unknown fields (Codable's default) and every
// string enum tolerates unknown values, so additive server changes never break decoding (§9).

/// A string enum that keeps unknown raw values instead of failing to decode.
protocol OpenEnum: Codable, Hashable, Sendable, RawRepresentable where RawValue == String {
    static var unknownFallback: Self { get }
}

extension OpenEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknownFallback
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AuthorType: String, OpenEnum {
    case customer, agent, system, unknown
    static var unknownFallback: AuthorType { .unknown }
}

enum MessageKind: String, OpenEnum {
    case text, card, event, unknown
    static var unknownFallback: MessageKind { .unknown }
}

enum AgentMessageStatus: String, OpenEnum {
    case sent, delivered, read, unknown
    static var unknownFallback: AgentMessageStatus { .unknown }
}

enum AttachmentKind: String, OpenEnum {
    case image, file, unknown
    static var unknownFallback: AttachmentKind { .unknown }
}

struct Author: Codable, Hashable, Sendable {
    var type: AuthorType
    var id: String?
    var name: String?
    var avatarUrl: String?
}

struct Translation: Codable, Hashable, Sendable {
    var language: String
    var text: String
}

struct Card: Codable, Hashable, Sendable {
    /// Raw card type. Known values are `review`, `offer`, `app` and `code`; anything else renders
    /// as plain text.
    var type: String
    var title: String?
    /// Short supporting line (app pitch, campaign description).
    var body: String?
    var buttonLabel: String?
    /// Already resolved for this device by the server.
    var url: String?
    var paywallId: String?
    /// App promo: the promoted app.
    var promotedAppId: String?
    var appStoreId: String?
    var iconUrl: String?
    /// App promo: this customer already uses the promoted app.
    var installed: Bool?
    /// Code card.
    var code: String?
    var campaignId: String?
    /// Where the code can be redeemed: `ios`, `android`, `web` or `any`.
    var platform: String?
    /// ISO 8601. Kept as a string so a malformed date never drops the whole card.
    var expiresAt: String?
    var available: Bool?
    var openedAt: String?

    init(type: String, title: String? = nil, body: String? = nil, buttonLabel: String? = nil, url: String? = nil,
         paywallId: String? = nil, promotedAppId: String? = nil, appStoreId: String? = nil, iconUrl: String? = nil,
         installed: Bool? = nil, code: String? = nil, campaignId: String? = nil, platform: String? = nil,
         expiresAt: String? = nil, available: Bool? = nil, openedAt: String? = nil) {
        self.type = type
        self.title = title
        self.body = body
        self.buttonLabel = buttonLabel
        self.url = url
        self.paywallId = paywallId
        self.promotedAppId = promotedAppId
        self.appStoreId = appStoreId
        self.iconUrl = iconUrl
        self.installed = installed
        self.code = code
        self.campaignId = campaignId
        self.platform = platform
        self.expiresAt = expiresAt
        self.available = available
        self.openedAt = openedAt
    }

    enum Known: Equatable { case review, offer, app, code, unknown }

    var known: Known {
        switch type {
        case "review": return .review
        case "offer": return .offer
        case "app": return .app
        case "code": return .code
        default: return .unknown
        }
    }

    var expiryDate: Date? { expiresAt.flatMap(WireJSON.parseDate) }
}

struct Attachment: Codable, Hashable, Sendable {
    var id: String
    var kind: AttachmentKind
    var contentType: String
    var url: String
    var thumbnailUrl: String?
    var width: Int?
    var height: Int?
    var size: Int?
    var filename: String?
}

struct Message: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var conversationId: String
    var seq: Int
    var clientId: String?
    var author: Author
    var kind: MessageKind
    var text: String
    var language: String?
    var translation: Translation?
    var attachments: [Attachment]
    var card: Card?
    var createdAt: Date
    var status: AgentMessageStatus?

    enum CodingKeys: String, CodingKey {
        case id, conversationId, seq, clientId, author, kind, text, language, translation, attachments, card, createdAt, status
    }

    init(id: String, conversationId: String, seq: Int, clientId: String? = nil, author: Author, kind: MessageKind = .text,
         text: String, language: String? = nil, translation: Translation? = nil, attachments: [Attachment] = [],
         card: Card? = nil, createdAt: Date, status: AgentMessageStatus? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.seq = seq
        self.clientId = clientId
        self.author = author
        self.kind = kind
        self.text = text
        self.language = language
        self.translation = translation
        self.attachments = attachments
        self.card = card
        self.createdAt = createdAt
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId) ?? ""
        seq = try c.decode(Int.self, forKey: .seq)
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId)
        author = try c.decode(Author.self, forKey: .author)
        kind = try c.decodeIfPresent(MessageKind.self, forKey: .kind) ?? .text
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language)
        translation = try c.decodeIfPresent(Translation.self, forKey: .translation)
        attachments = (try? c.decodeIfPresent([Attachment].self, forKey: .attachments)) ?? []
        card = try? c.decodeIfPresent(Card.self, forKey: .card)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        status = try c.decodeIfPresent(AgentMessageStatus.self, forKey: .status)
    }

    /// `event` messages are inbox-only and must never be shown (§5), and unknown kinds are skipped
    /// unless they carry text.
    var isDisplayable: Bool {
        switch kind {
        case .event: return false
        case .unknown: return !text.isEmpty || !attachments.isEmpty
        default: return true
        }
    }

    var isFromCustomer: Bool { author.type == .customer }
}

struct Conversation: Codable, Hashable, Sendable {
    var id: String
    var status: String?
    var lastSeq: Int
    var customerReadSeq: Int?
    var agentReadSeq: Int?
    var unread: Int?
    var createdAt: Date?
}

struct ColorPair: Codable, Hashable, Sendable {
    var light: String
    var dark: String
}

/// The published appearance from `GET /v1/sdk/appearance` (§5 Appearance). Every field is optional.
struct RemoteAppearance: Codable, Hashable, Sendable {
    struct Colors: Codable, Hashable, Sendable {
        var accent: ColorPair?
        var onAccent: ColorPair?
        var background: ColorPair?
        var incomingBackground: ColorPair?
        var incomingForeground: ColorPair?
    }

    var colors: Colors?
    var title: [String: String]?
    var welcomeTitle: [String: String]?
    var welcomeText: [String: String]?
    var colorScheme: String?
    var fontStyle: String?
    var cornerStyle: String?
    var showCloseButton: Bool?
    var welcomeIconUrl: String?
    var fadeOlderMessages: Bool?
    var updatedAt: String?
}

struct SdkConfig: Codable, Hashable, Sendable {
    struct TranslationConfig: Codable, Hashable, Sendable {
        var enabled: Bool?
        var customerLanguage: String?
    }

    struct TeamDisplay: Codable, Hashable, Sendable {
        var showNames: Bool?
        var showPhotos: Bool?
    }

    struct Uploads: Codable, Hashable, Sendable {
        var images: Bool?
        var files: Bool?
    }

    var appId: String?
    var appName: String?
    var verifiedOnly: Bool?
    var blocked: Bool?
    var trackedEvents: [String]?
    var translation: TranslationConfig?
    var teamDisplay: TeamDisplay?
    var uploads: Uploads?
    var pollIntervalSeconds: Int?
    var appearanceEtag: String?

    var allowsImages: Bool { uploads?.images ?? true }
    var allowsFiles: Bool { uploads?.files ?? true }
    var pollInterval: TimeInterval { TimeInterval(max(5, pollIntervalSeconds ?? 60)) }
}

struct SdkCustomer: Codable, Hashable, Sendable {
    var id: String
    var verified: Bool?
    var userId: String?
    var name: String?
    var email: String?
}

// MARK: - Requests and responses (§3)

struct DeviceInfo: Codable, Hashable, Sendable {
    var model: String?
    var osVersion: String?
    var appVersion: String?
    var appBuild: String?
    var bundleId: String?
    var locale: String?
    var language: String?
    var timeZone: String?
}

struct IdentityInput: Codable, Hashable, Sendable {
    var userId: String?
    var name: String?
    var email: String?
    var token: String?

    var isEmpty: Bool { userId == nil && name == nil && email == nil && token == nil }
}

struct PushInput: Codable, Hashable, Sendable {
    var token: String
    var provider: String
    var environment: String?
}

struct PaywallInput: Codable, Hashable, Sendable {
    struct Product: Codable, Hashable, Sendable {
        var id: String
        var price: String?
        var period: String?
        var trial: String?
    }

    var id: String
    var title: String
    var products: [Product]?
}

struct RegisterRequest: Encodable, Sendable {
    var platform: String = "ios"
    var device: DeviceInfo
    var identity: IdentityInput?
    var metadata: [String: String]?
    var push: PushInput?
}

struct RegisterResponse: Codable, Sendable {
    var deviceToken: String
    var registrationId: String
    var customer: SdkCustomer
    var config: SdkConfig
}

/// `PATCH /v1/sdk/device`. Only changed fields are encoded; `push` distinguishes "unchanged" from
/// "remove" (`null`).
struct DeviceUpdateRequest: Encodable, Sendable {
    enum PushChange: Sendable, Equatable {
        case set(PushInput)
        case remove
    }

    var identity: IdentityInput?
    var metadata: [String: String]?
    var push: PushChange?
    var device: DeviceInfo?
    var badgeEnabled: Bool?
    var paywalls: [PaywallInput]?

    var isEmpty: Bool {
        identity == nil && metadata == nil && push == nil && device == nil && badgeEnabled == nil && paywalls == nil
    }

    enum CodingKeys: String, CodingKey { case identity, metadata, push, device, badgeEnabled, paywalls }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(identity, forKey: .identity)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        switch push {
        case .set(let value): try c.encode(value, forKey: .push)
        case .remove: try c.encodeNil(forKey: .push)
        case nil: break
        }
        try c.encodeIfPresent(device, forKey: .device)
        try c.encodeIfPresent(badgeEnabled, forKey: .badgeEnabled)
        try c.encodeIfPresent(paywalls, forKey: .paywalls)
    }
}

struct DeviceUpdateResponse: Codable, Sendable {
    var customer: SdkCustomer?
    var config: SdkConfig?
}

struct ConversationResponse: Codable, Sendable {
    var conversation: Conversation?
    var messages: [Message]
    var hasMore: Bool

    init(conversation: Conversation?, messages: [Message], hasMore: Bool) {
        self.conversation = conversation
        self.messages = messages
        self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decodeIfPresent(Conversation.self, forKey: .conversation)
        messages = try c.decodeIfPresent(LossyArray<Message>.self, forKey: .messages)?.elements ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

struct MessagesResponse: Codable, Sendable {
    var messages: [Message]
    var hasMore: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent(LossyArray<Message>.self, forKey: .messages)?.elements ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

struct SendMessageRequest: Codable, Sendable {
    var clientId: String
    var text: String?
    var attachments: [String]?
}

struct SendMessageResponse: Codable, Sendable {
    var message: Message
}

struct UnreadResponse: Codable, Sendable {
    var count: Int
    var conversationId: String?
}

struct UploadRequest: Codable, Sendable {
    var contentType: String
    var size: Int
    var width: Int?
    var height: Int?
    var filename: String?
}

struct UploadResponse: Codable, Sendable {
    var uploadId: String
    var uploadUrl: String
    var expiresAt: String?
}

struct UploadCompleteResponse: Codable, Sendable {
    var attachment: Attachment
}

struct TrackRequest: Codable, Sendable {
    var name: String
    var opensChat: Bool
}

struct TrackResponse: Codable, Sendable {
    var openChat: Bool?
}

struct ErrorEnvelope: Codable, Sendable {
    struct Body: Codable, Sendable {
        var code: String
        var message: String?
        var retryAfter: Double?
    }

    var error: Body
}

/// Decodes an array, skipping elements that fail to decode instead of failing the whole array.
struct LossyArray<Element: Decodable & Sendable>: Decodable, Sendable {
    var elements: [Element]

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        elements = result
    }
}

extension LossyArray: Encodable where Element: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(contentsOf: elements)
    }
}

// MARK: - JSON coding

enum WireJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = parseDate(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(string)")
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func parseDate(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        return try? Date.ISO8601FormatStyle().parse(string)
    }

    static func formatDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
