import Foundation

/// An error from Support Yaps: a server error code from the protocol (`rate_limited`,
/// `identity_token_expired`, …) or an SDK code such as `connection_failed`.
///
/// Codes are an open set. Match the ones you care about and keep a fallback.
public struct SupportError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The server's error code, or an SDK-generated code.
    public let code: String
    /// The HTTP status, or `0` for transport, storage or configuration failures.
    public let status: Int
    /// Seconds to wait before retrying, present for `rate_limited`.
    public let retryAfter: TimeInterval?
    /// A developer-facing message. Never show it to users and never branch on it.
    public let message: String?

    public init(code: String, status: Int = 0, retryAfter: TimeInterval? = nil, message: String? = nil) {
        self.code = code
        self.status = status
        self.retryAfter = retryAfter
        self.message = message
    }

    public var description: String {
        "SupportError(\(code), status: \(status)\(retryAfter.map { ", retryAfter: \($0)" } ?? ""))"
    }

    // Server codes (PROTOCOL §1)
    public static let invalidRequest = "invalid_request"
    public static let unauthorized = "unauthorized"
    public static let identityTokenInvalid = "identity_token_invalid"
    public static let identityTokenExpired = "identity_token_expired"
    public static let identityMismatch = "identity_mismatch"
    public static let verificationRequired = "verification_required"
    public static let blocked = "blocked"
    public static let notFound = "not_found"
    public static let unknownApp = "unknown_app"
    public static let tooLarge = "too_large"
    public static let rateLimited = "rate_limited"
    public static let serverError = "server_error"

    // SDK codes
    public static let connectionFailed = "connection_failed"
    public static let cancelled = "cancelled"
    public static let notConfigured = "not_configured"
    public static let invalidResponse = "invalid_response"
    public static let secureStorageUnavailable = "secure_storage_unavailable"

    /// Whether the request may succeed if repeated later (429, 5xx and transport failures).
    public var isRetryable: Bool {
        status == 429 || status >= 500 || status == 0 && code != SupportError.notConfigured && code != SupportError.cancelled
    }

    /// Whether the server definitively rejected the request (a 4xx other than 429).
    var isPermanentRejection: Bool { status >= 400 && status < 500 && status != 429 }
}

/// Something that happened in Support chat. Events never carry message bodies or user identifiers.
public enum SupportEvent: Hashable, Sendable {
    /// Chat content appeared, in the SDK sheet or a host-owned ``SupportChatView``.
    case chatOpened
    /// Chat content disappeared.
    case chatClosed
    /// The server confirmed a message the customer sent (including retries).
    case messageSent
    /// A new reply from the team arrived while the chat was visible.
    case messageReceived
    /// Fired right after ``messageSent`` when the confirmed message contained images.
    case imageSent
    /// A review card was tapped, just before its App Store URL opens.
    case reviewOpened
    /// An available offer card was tapped and `onPaywall` was called.
    case paywallOpened
    /// An app promo card's "Get it" was tapped, just before the App Store sheet (or page) opens.
    case appPromoOpened
    /// A code card's Copy was tapped and the code is on the pasteboard.
    case codeCopied
    /// A code card's Redeem was tapped, just before its redemption URL opens.
    case codeOpened
    /// `deleteData()` completed.
    case dataDeleted
    /// The server rejected the identity token from `identify(token:)`. The SDK dropped it and keeps
    /// chatting unverified.
    case identityRejected(SupportError)
}

/// A paywall your app can present when an agent sends an offer card.
public struct SupportPaywall: Hashable, Sendable, Identifiable {
    public struct Product: Hashable, Sendable {
        public var id: String
        /// Display price, for example `"$29.99"`. Shown to agents only.
        public var price: String?
        /// ISO 8601 duration, for example `"P1Y"`.
        public var period: String?
        /// ISO 8601 duration of the free trial, for example `"P1W"`.
        public var trial: String?

        public init(id: String, price: String? = nil, period: String? = nil, trial: String? = nil) {
            self.id = id
            self.price = price
            self.period = period
            self.trial = trial
        }
    }

    /// Stable identifier, 1–64 characters of `[A-Za-z0-9_.-]`. Passed back to `onPaywall`.
    public var id: String
    /// What agents see in the inbox, at most 60 characters. Customers never see it.
    public var title: String
    /// Optional products so agents can see what the offer contains.
    public var products: [Product]

    public init(id: String, title: String, products: [Product] = []) {
        self.id = id
        self.title = title
        self.products = products
    }
}

/// Which APNs environment a push token belongs to.
public enum PushEnvironment: String, Sendable, Hashable {
    /// Read `aps-environment` from the embedded provisioning profile. Sandbox on the simulator,
    /// production when there is no profile (App Store and TestFlight).
    case automatic
    case sandbox
    case production
}

/// Minimum level of SDK log lines.
public enum SupportLogLevel: Int, Comparable, Sendable, CaseIterable {
    case off = 0
    case error = 1
    case info = 2
    case debug = 3

    public static func < (lhs: SupportLogLevel, rhs: SupportLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}
