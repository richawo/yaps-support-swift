import Foundation

/// A local file waiting to be uploaded with a pending message.
struct PendingAttachment: Codable, Hashable, Sendable {
    /// File name relative to the SDK's storage folder.
    var localFile: String
    var kind: AttachmentKind
    var contentType: String
    var filename: String?
    var width: Int?
    var height: Int?
    var size: Int
    /// Set once the upload finished, so a retry doesn't upload again.
    var uploadId: String?
}

/// A message the customer sent that the server hasn't confirmed yet.
struct PendingMessage: Codable, Hashable, Sendable, Identifiable {
    enum State: String, Codable, Sendable {
        case queued, sending, failed
    }

    var clientId: String
    var text: String
    var attachments: [PendingAttachment]
    var createdAt: Date
    var attempts: Int = 0
    var nextAttemptAt: Date?
    var state: State = .queued
    var lastErrorCode: String?

    var id: String { clientId }
    var hasImages: Bool { attachments.contains { $0.kind == .image } }
}

/// Persistent queue of outgoing messages (PROTOCOL §3.6): persist first, then send; retry with
/// backoff; mark failed after `maxAttempts` attempts or on a definitive 4xx. Messages are sent in
/// order, so a message waiting for its retry holds back the ones after it.
struct Outbox: Codable, Sendable, Equatable {
    static let maxAttempts = 5

    private(set) var items: [PendingMessage] = []

    init(items: [PendingMessage] = []) {
        self.items = items
    }

    var isEmpty: Bool { items.isEmpty }

    func item(_ clientId: String) -> PendingMessage? { items.first { $0.clientId == clientId } }

    /// Adds a message. Returns false (and changes nothing) when the client ID is already queued.
    @discardableResult
    mutating func enqueue(_ message: PendingMessage) -> Bool {
        guard item(message.clientId) == nil else { return false }
        items.append(message)
        return true
    }

    /// The next message to send now: the oldest that hasn't failed, if its retry time has come.
    func nextDue(now: Date) -> PendingMessage? {
        guard let head = items.first(where: { $0.state != .failed }) else { return nil }
        guard head.state == .queued else { return nil }
        if let next = head.nextAttemptAt, next > now { return nil }
        return head
    }

    /// When the queue next needs attention, if a retry is scheduled.
    func nextWakeUp() -> Date? {
        guard let head = items.first(where: { $0.state != .failed }), head.state == .queued else { return nil }
        return head.nextAttemptAt
    }

    mutating func markSending(_ clientId: String) {
        update(clientId) { $0.state = .sending }
    }

    /// Records a failed attempt and schedules the retry. Returns the item's new state.
    @discardableResult
    mutating func recordFailure(_ clientId: String, error: SupportError, now: Date,
                                jitter: Double = Double.random(in: -0.2...0.2)) -> PendingMessage.State? {
        var newState: PendingMessage.State?
        update(clientId) { item in
            item.attempts += 1
            item.lastErrorCode = error.code
            if error.isPermanentRejection || item.attempts >= Self.maxAttempts {
                item.state = .failed
                item.nextAttemptAt = nil
            } else {
                item.state = .queued
                let delay = error.status == 429 ? (error.retryAfter ?? Backoff.rest(attempt: item.attempts - 1, jitter: jitter))
                    : Backoff.rest(attempt: item.attempts - 1, jitter: jitter)
                item.nextAttemptAt = now.addingTimeInterval(delay)
            }
            newState = item.state
        }
        return newState
    }

    /// Marks a message failed without counting an attempt (blocked, verification required).
    mutating func markFailed(_ clientId: String, code: String) {
        update(clientId) {
            $0.state = .failed
            $0.lastErrorCode = code
            $0.nextAttemptAt = nil
        }
    }

    /// The server stored the message; drop it from the queue.
    @discardableResult
    mutating func confirm(_ clientId: String) -> PendingMessage? {
        guard let index = items.firstIndex(where: { $0.clientId == clientId }) else { return nil }
        return items.remove(at: index)
    }

    /// Drops queued messages whose client ID already appears in server messages (a retry the server
    /// deduplicated, or an ack we missed). Returns the removed items.
    @discardableResult
    mutating func reconcile(with messages: [Message]) -> [PendingMessage] {
        let confirmed = Set(messages.compactMap(\.clientId))
        guard !confirmed.isEmpty else { return [] }
        let removed = items.filter { confirmed.contains($0.clientId) }
        items.removeAll { confirmed.contains($0.clientId) }
        return removed
    }

    /// Manual retry from the UI: back to the queue with a fresh attempt budget.
    mutating func retry(_ clientId: String, now: Date) {
        update(clientId) {
            $0.state = .queued
            $0.attempts = 0
            $0.nextAttemptAt = now
            $0.lastErrorCode = nil
        }
    }

    /// Retries every message that failed only because sending was blocked or needed verification.
    mutating func retryAll(now: Date) {
        for item in items where item.state == .failed { retry(item.clientId, now: now) }
    }

    @discardableResult
    mutating func remove(_ clientId: String) -> PendingMessage? { confirm(clientId) }

    mutating func setUploadID(_ uploadId: String, clientId: String, attachmentIndex: Int) {
        update(clientId) { item in
            guard item.attachments.indices.contains(attachmentIndex) else { return }
            item.attachments[attachmentIndex].uploadId = uploadId
        }
    }

    /// After a relaunch nothing is in flight: put interrupted sends back in the queue.
    mutating func recoverInterrupted() {
        for index in items.indices where items[index].state == .sending {
            items[index].state = .queued
            items[index].nextAttemptAt = nil
        }
    }

    private mutating func update(_ clientId: String, _ change: (inout PendingMessage) -> Void) {
        guard let index = items.firstIndex(where: { $0.clientId == clientId }) else { return }
        change(&items[index])
    }
}

/// The local copy of the conversation: messages sorted by `seq`, unique by `id`, capped at the
/// latest `limit` messages when persisted.
struct MessageCache: Codable, Sendable, Equatable {
    static let limit = 200

    private(set) var messages: [Message] = []
    var hasMore: Bool = false
    var conversationId: String?
    var agentReadSeq: Int = 0
    var customerReadSeq: Int = 0

    init(messages: [Message] = [], hasMore: Bool = false) {
        self.messages = []
        self.hasMore = hasMore
        merge(messages)
    }

    var lastSeq: Int { messages.last?.seq ?? 0 }
    var firstSeq: Int? { messages.first?.seq }

    /// Inserts or replaces messages by `id`, keeping seq order. Returns the IDs that were new.
    @discardableResult
    mutating func merge(_ incoming: [Message]) -> [String] {
        var added: [String] = []
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in incoming where message.isDisplayable {
            if byID[message.id] == nil { added.append(message.id) }
            byID[message.id] = message
        }
        messages = byID.values.sorted { ($0.seq, $0.createdAt) < ($1.seq, $1.createdAt) }
        if conversationId == nil { conversationId = incoming.first?.conversationId }
        return added
    }

    /// Applies the latest page from `GET /conversation`. If it doesn't overlap the cache, the cache
    /// is stale (for example after a long time offline) and is replaced so there are no gaps.
    mutating func applyLatestPage(_ page: [Message], hasMore: Bool) {
        let displayable = page.filter(\.isDisplayable)
        if let oldestInPage = page.map(\.seq).min(), oldestInPage > lastSeq + 1, !messages.isEmpty {
            messages = []
            merge(displayable)
            self.hasMore = hasMore
        } else {
            merge(displayable)
            if messages.count <= displayable.count { self.hasMore = hasMore }
        }
    }

    mutating func prependOlder(_ page: [Message], hasMore: Bool) {
        merge(page)
        self.hasMore = hasMore
    }

    /// The copy written to disk: the latest `limit` messages.
    var persisted: MessageCache {
        var copy = self
        if copy.messages.count > Self.limit {
            copy.messages = Array(copy.messages.suffix(Self.limit))
            copy.hasMore = true
        }
        return copy
    }

    mutating func reset() { self = MessageCache() }
}
