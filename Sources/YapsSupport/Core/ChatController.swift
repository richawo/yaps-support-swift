import Foundation
import UIKit

/// An attachment picked in the composer, not sent yet. Kept in memory only.
struct DraftAttachment: Identifiable, Equatable {
    let id = UUID()
    var kind: AttachmentKind
    var data: Data
    var contentType: String
    var filename: String
    var width: Int?
    var height: Int?
    var preview: UIImage?
}

/// The live conversation: cache, outbox, socket, polling, read state and typing.
@MainActor
final class ChatController: ObservableObject {
    enum Connection: Equatable {
        case hidden
        case offline
        case connecting
        case connected
        /// Live updates unavailable; checking for new messages periodically.
        case polling
    }

    enum Restriction: Equatable {
        case none
        case blocked
        case verificationRequired
    }

    enum LoadState: Equatable {
        case idle, loading, loaded, failed
    }

    @Published private(set) var rows: [ChatRow] = []
    @Published private(set) var hasMore = false
    @Published private(set) var isLoadingEarlier = false
    @Published private(set) var agentTyping = false
    @Published private(set) var connection: Connection = .hidden
    @Published private(set) var restriction: Restriction = .none
    @Published private(set) var loadState: LoadState = .idle
    /// Attachments handed to the composer from outside it (previews). Consumed on appear.
    var seededAttachments: [DraftAttachment] = []

    @Published var draft: String = "" {
        didSet {
            guard draft != oldValue else { return }
            engine.deps.defaults.set(draft.isEmpty ? nil : draft, forKey: draftKey)
            draftChanged()
        }
    }

    private unowned let engine: SupportEngine
    private(set) var cache: MessageCache
    private(set) var outbox: Outbox
    private var realtime: RealtimeClient?
    private var visibleCount = 0
    private var appActive = true
    private var uploadProgress: [String: Double] = [:]
    private var pendingAcks: [String: CheckedContinuation<Message, Error>] = [:]
    private var drainTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var typingStopTask: Task<Void, Never>?
    private var connectedBannerTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var scheduledExpiry: Date?
    private var lastTypingSentAt: Date?
    private var typingOn = false
    private var hadConnectionTrouble = false
    private var restrictionFromError: Restriction = .none

    private static let messagesFile = "messages.json"
    private static let outboxFile = "outbox.json"
    private static let outboxFolder = "outbox-files"
    private var draftKey: String { "ai.yaps.support.\(engine.appID).draft" }

    static let ackTimeout: TimeInterval = 15

    init(engine: SupportEngine) {
        self.engine = engine
        cache = engine.deps.fileStore.load(MessageCache.self, from: Self.messagesFile) ?? MessageCache()
        var outbox = engine.deps.fileStore.load(Outbox.self, from: Self.outboxFile) ?? Outbox()
        outbox.recoverInterrupted()
        self.outbox = outbox
        draft = engine.deps.defaults.string(forKey: "ai.yaps.support.\(engine.appID).draft") ?? ""
        hasMore = cache.hasMore
        configChanged()
        rebuildRows()
    }

    var isVisible: Bool { visibleCount > 0 }
    var conversationId: String? { cache.conversationId }

    // MARK: - Visibility

    func chatDidAppear() {
        visibleCount += 1
        guard visibleCount == 1 else { return }
        engine.onChatVisibilityChange?(true)
        engine.emit(.chatOpened)
        startLive()
    }

    func chatDidDisappear() {
        visibleCount = max(0, visibleCount - 1)
        guard visibleCount == 0 else { return }
        stopLive()
        engine.onChatVisibilityChange?(false)
        engine.emit(.chatClosed)
        Task { await engine.refreshUnread() }
    }

    func appDidBecomeActive() {
        appActive = true
        if isVisible { startLive() }
        drain()
    }

    func appDidEnterBackground() {
        appActive = false
        if isVisible { sendTyping(false) }
        stopLive()
    }

    func shutdown() {
        stopLive()
        drainTask?.cancel()
        wakeTask?.cancel()
        expiryTask?.cancel()
    }

    // MARK: - Live updates

    private func startLive() {
        guard appActive, liveTask == nil else { return }
        if cache.messages.isEmpty && loadState != .loaded { loadState = .loading }
        liveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.ensureRegistered()
                await self.loadLatest()
                guard self.isVisible, self.appActive else { self.liveTask = nil; return }
                self.connectRealtime()
                self.drain()
            } catch {
                if self.cache.messages.isEmpty { self.loadState = .failed }
                self.connection = .offline
                self.hadConnectionTrouble = true
                self.liveTask = nil
                // Try again shortly while the chat stays open.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if self.isVisible, self.appActive { self.startLive() }
            }
        }
    }

    private func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        realtime?.stop()
        realtime = nil
        stopPolling()
        typingStopTask?.cancel()
        failPendingAcks()
        agentTyping = false
        connection = .hidden
    }

    /// Fetches the latest page and reconciles it with the cache and outbox.
    func loadLatest() async {
        do {
            let response: ConversationResponse = try await engine.authorized { token in
                try await engine.api.send(.get, "/v1/sdk/conversation", token: token, retry: .standard)
            }
            let previousIDs = Set(cache.messages.map(\.id))
            cache.applyLatestPage(response.messages, hasMore: response.hasMore)
            if let conversation = response.conversation {
                cache.conversationId = conversation.id
                cache.agentReadSeq = max(cache.agentReadSeq, conversation.agentReadSeq ?? 0)
                cache.customerReadSeq = max(cache.customerReadSeq, conversation.customerReadSeq ?? 0)
                engine.setUnread(conversation.unread ?? 0)
            }
            outbox.reconcile(with: response.messages)
            hasMore = cache.hasMore
            loadState = .loaded
            saveAll()
            rebuildRows()
            if !previousIDs.isEmpty {
                let newAgent = response.messages.contains { !previousIDs.contains($0.id) && !$0.isFromCustomer && $0.isDisplayable }
                if newAgent && isVisible { engine.emit(.messageReceived) }
            }
            markRead()
        } catch {
            if cache.messages.isEmpty { loadState = .failed }
            Log.debug("Loading the conversation failed")
        }
    }

    func refreshNow() {
        guard isVisible else { return }
        Task { await loadLatest() }
    }

    private func socketURL() -> URL? {
        guard let token = engine.deviceToken,
              var components = URLComponents(url: engine.api.url("/v1/sdk/ws"), resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    private func connectRealtime() {
        guard engine.deps.realtimeEnabled else {
            connection = .hidden
            return
        }
        if let realtime {
            realtime.reconnectNow()
            return
        }
        let client = RealtimeClient(makeURL: { [weak self] in self?.socketURL() },
                                    lastSeq: { [weak self] in self?.cache.lastSeq ?? 0 })
        client.onFrame = { [weak self] frame in self?.handle(frame) }
        client.onStateChange = { [weak self] state in self?.realtimeStateChanged(state) }
        client.onFailure = { [weak self] failure in
            guard let self else { return }
            self.failPendingAcks()
            if failure == .unauthorized {
                self.engine.dropDeviceToken()
                Task { _ = try? await self.engine.ensureRegistered() }
            }
        }
        realtime = client
        client.start()
    }

    private func realtimeStateChanged(_ state: RealtimeClient.State) {
        switch state {
        case .idle:
            break
        case .connecting:
            if hadConnectionTrouble && pollTask == nil { connection = .connecting }
        case .connected:
            stopPolling()
            if hadConnectionTrouble {
                hadConnectionTrouble = false
                connection = .connected
                connectedBannerTask?.cancel()
                connectedBannerTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled, self?.connection == .connected else { return }
                    self?.connection = .hidden
                }
            } else {
                connection = .hidden
            }
            // Messages that arrived while we were reconnecting come via the hello replay.
            drain()
        case .waiting(let failures, _):
            hadConnectionTrouble = true
            agentTyping = false
            if failures >= 2 {
                startPolling()
            } else {
                connection = .connecting
            }
        }
    }

    private func startPolling() {
        connection = .polling
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let interval = self.engine.config?.pollInterval ?? 60
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// REST catch-up when the socket is unavailable (§4).
    func poll() async {
        do {
            let after = cache.lastSeq
            let response: MessagesResponse = try await engine.authorized { token in
                try await engine.api.send(.get, "/v1/sdk/messages", query: [URLQueryItem(name: "after", value: String(after))],
                                          token: token, retry: .none)
            }
            receive(response.messages)
        } catch {
            Log.debug("Polling failed")
        }
    }

    // MARK: - Frames

    func handle(_ frame: ServerFrame) {
        switch frame {
        case .welcome(let conversationId, _):
            if let conversationId { cache.conversationId = conversationId }
        case .message(let message):
            receive([message])
        case .update(let message):
            cache.merge([message])
            saveCache()
            rebuildRows()
        case .ack(let cid, let message):
            if let continuation = pendingAcks.removeValue(forKey: cid) {
                continuation.resume(returning: message)
            } else {
                outbox.confirm(cid)
                receive([message])
            }
        case .state(let typing, let agentReadSeq, let customerReadSeq):
            if let typing { agentTyping = typing }
            if let agentReadSeq, agentReadSeq > cache.agentReadSeq {
                cache.agentReadSeq = agentReadSeq
                rebuildRows()
            }
            if let customerReadSeq { cache.customerReadSeq = max(cache.customerReadSeq, customerReadSeq) }
        case .error(let code, let cid, _):
            let error = SupportError(code: code, status: Self.status(forCode: code))
            if let cid, let continuation = pendingAcks.removeValue(forKey: cid) {
                continuation.resume(throwing: error)
            } else {
                Log.debug("Socket error \(code)")
            }
        case .pong, .unknown:
            break
        }
    }

    /// Merges new messages from the socket or polling.
    private func receive(_ messages: [Message]) {
        guard !messages.isEmpty else { return }
        let added = Set(cache.merge(messages))
        let removed = outbox.reconcile(with: messages)
        if messages.contains(where: { added.contains($0.id) && !$0.isFromCustomer }) {
            agentTyping = false
            if isVisible { engine.emit(.messageReceived) }
        }
        if !removed.isEmpty { saveOutbox() }
        saveCache()
        rebuildRows()
        markRead()
    }

    static func status(forCode code: String) -> Int {
        switch code {
        case SupportError.rateLimited: return 429
        case SupportError.invalidRequest: return 400
        case SupportError.unauthorized, SupportError.identityTokenInvalid, SupportError.identityTokenExpired: return 401
        case SupportError.blocked, SupportError.verificationRequired, SupportError.identityMismatch, "forbidden": return 403
        case SupportError.notFound, SupportError.unknownApp: return 404
        case SupportError.tooLarge: return 413
        default: return 500
        }
    }

    // MARK: - Read state

    func markRead() {
        guard isVisible, appActive else { return }
        let lastSeq = cache.lastSeq
        guard lastSeq > cache.customerReadSeq,
              cache.messages.contains(where: { !$0.isFromCustomer && $0.seq > cache.customerReadSeq }) else {
            if engine.unreadCount != 0 && cache.messages.last.map({ $0.seq <= cache.customerReadSeq }) == true {
                engine.setUnread(0)
            }
            return
        }
        cache.customerReadSeq = lastSeq
        saveCache()
        engine.setUnread(0)
        if realtime?.isConnected == true, realtime?.send(.read(seq: lastSeq)) == true { return }
        Task {
            try? await engine.authorized { token in
                try await engine.api.sendVoid(.post, "/v1/sdk/read", body: ["seq": lastSeq], token: token, retry: .standard)
            }
        }
    }

    // MARK: - Typing

    private func draftChanged() {
        guard isVisible, restriction == .none else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendTyping(false)
            return
        }
        let now = engine.deps.now()
        if !typingOn || lastTypingSentAt.map({ now.timeIntervalSince($0) >= 3 }) ?? true {
            sendTyping(true)
        }
        typingStopTask?.cancel()
        typingStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.sendTyping(false)
        }
    }

    private func sendTyping(_ on: Bool) {
        guard on || typingOn else { return }
        typingOn = on
        lastTypingSentAt = on ? engine.deps.now() : nil
        if realtime?.isConnected == true, realtime?.send(.typing(on: on)) == true { return }
        guard pollTask != nil, cache.conversationId != nil, engine.deviceToken != nil else { return }
        Task {
            try? await engine.authorized { token in
                try await engine.api.sendVoid(.post, "/v1/sdk/typing", body: ["typing": on], token: token, retry: .none)
            }
        }
    }

    // MARK: - History

    func loadEarlier() async {
        guard hasMore, !isLoadingEarlier, let first = cache.firstSeq else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            let response: MessagesResponse = try await engine.authorized { token in
                try await engine.api.send(.get, "/v1/sdk/messages",
                                          query: [URLQueryItem(name: "before", value: String(first)), URLQueryItem(name: "limit", value: "50")],
                                          token: token, retry: .standard)
            }
            cache.prependOlder(response.messages, hasMore: response.hasMore)
            hasMore = cache.hasMore
            saveCache()
            rebuildRows()
        } catch {
            Log.debug("Loading earlier messages failed")
        }
    }

    // MARK: - Sending

    enum SendValidation: Equatable {
        case ok, empty, tooLong, tooManyAttachments, restricted
    }

    func validate(text: String, attachments: [DraftAttachment]) -> SendValidation {
        if restriction != .none { return .restricted }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty { return .empty }
        if Validation.utf16Length(trimmed) > Validation.messageTextLimit { return .tooLong }
        if attachments.count > Validation.attachmentsPerMessage { return .tooManyAttachments }
        return .ok
    }

    /// Persists a message to the outbox and starts delivering it. Returns false if it wasn't valid.
    @discardableResult
    func send(text: String, attachments: [DraftAttachment]) -> Bool {
        guard validate(text: text, attachments: attachments) == .ok else { return false }
        let clientId = ULID.make(date: engine.deps.now())
        var pendingAttachments: [PendingAttachment] = []
        for (index, attachment) in attachments.enumerated() {
            let ext = attachment.kind == .image ? "jpg" : (attachment.filename as NSString).pathExtension
            let name = "\(Self.outboxFolder)/\(clientId)-\(index).\(ext.isEmpty ? "bin" : ext)"
            do {
                _ = try engine.deps.fileStore.writeData(attachment.data, to: name)
            } catch {
                Log.error("Couldn't store an attachment for sending")
                return false
            }
            pendingAttachments.append(PendingAttachment(localFile: name, kind: attachment.kind, contentType: attachment.contentType,
                                                        filename: attachment.filename, width: attachment.width,
                                                        height: attachment.height, size: attachment.data.count))
        }
        let pending = PendingMessage(clientId: clientId, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                     attachments: pendingAttachments, createdAt: engine.deps.now())
        guard outbox.enqueue(pending) else { return false }
        saveOutbox()
        draft = ""
        sendTyping(false)
        rebuildRows()
        drain()
        return true
    }

    func retry(clientId: String) {
        outbox.retry(clientId, now: engine.deps.now())
        if restriction == .none || restrictionFromError != .none {
            restrictionFromError = .none
            configChanged()
        }
        saveOutbox()
        rebuildRows()
        drain()
    }

    func discard(clientId: String) {
        if let removed = outbox.remove(clientId) { deleteFiles(of: removed) }
        saveOutbox()
        rebuildRows()
    }

    /// Delivers queued messages one at a time, oldest first.
    func drain() {
        guard drainTask == nil, appActive, restriction == .none else { return }
        wakeTask?.cancel()
        wakeTask = nil
        drainTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let item = self.outbox.nextDue(now: self.engine.deps.now()) {
                await self.deliverOne(item)
                if self.restriction != .none { break }
            }
            self.drainTask = nil
            self.scheduleWake()
        }
    }

    /// Awaits the current delivery pass (tests).
    func waitForDrain() async {
        while let task = drainTask { await task.value }
    }

    private func scheduleWake() {
        guard let wake = outbox.nextWakeUp() else { return }
        let delay = max(0.05, wake.timeIntervalSince(engine.deps.now()))
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await self?.engine.deps.sleeper(delay)
            guard !Task.isCancelled else { return }
            self?.wakeTask = nil
            self?.drain()
        }
    }

    private func deliverOne(_ item: PendingMessage) async {
        outbox.markSending(item.clientId)
        saveOutbox()
        rebuildRows()
        do {
            let message = try await deliver(item)
            if let confirmed = outbox.confirm(item.clientId) { deleteFiles(of: confirmed) }
            uploadProgress[item.clientId] = nil
            cache.merge([message])
            saveAll()
            rebuildRows()
            engine.emit(.messageSent)
            if item.hasImages { engine.emit(.imageSent) }
        } catch {
            let error = APIClient.transportError(error)
            uploadProgress[item.clientId] = nil
            switch error.code {
            case SupportError.blocked:
                restrictionFromError = .blocked
                restriction = .blocked
                outbox.markFailed(item.clientId, code: error.code)
            case SupportError.verificationRequired:
                restrictionFromError = .verificationRequired
                restriction = .verificationRequired
                outbox.markFailed(item.clientId, code: error.code)
            default:
                let state = outbox.recordFailure(item.clientId, error: error, now: engine.deps.now())
                Log.info("Sending a message failed (\(error.code)); \(state == .failed ? "marked as not delivered" : "will retry")")
            }
            saveOutbox()
            rebuildRows()
        }
    }

    private func deliver(_ item: PendingMessage) async throws -> Message {
        var uploadIDs: [String] = []
        let total = Double(max(1, item.attachments.count))
        for (index, attachment) in item.attachments.enumerated() {
            if let existing = attachment.uploadId {
                uploadIDs.append(existing)
                continue
            }
            let id = try await upload(attachment, clientId: item.clientId) { [weak self] fraction in
                Task { @MainActor in
                    self?.setProgress((Double(index) + fraction) / total, for: item.clientId)
                }
            }
            outbox.setUploadID(id, clientId: item.clientId, attachmentIndex: index)
            saveOutbox()
            uploadIDs.append(id)
        }
        let text = item.text.isEmpty ? nil : item.text
        let attachments = uploadIDs.isEmpty ? nil : uploadIDs
        if let realtime, realtime.isConnected {
            return try await sendViaSocket(cid: item.clientId, text: text, attachments: attachments)
        }
        let response: SendMessageResponse = try await engine.authorized { token in
            try await engine.api.send(.post, "/v1/sdk/messages",
                                      body: SendMessageRequest(clientId: item.clientId, text: text, attachments: attachments),
                                      token: token, retry: .none)
        }
        return response.message
    }

    private func setProgress(_ value: Double, for clientId: String) {
        guard outbox.item(clientId)?.state == .sending else { return }
        uploadProgress[clientId] = value
        rebuildRows()
    }

    /// PROTOCOL §3.7: create the upload, PUT the bytes, return the upload ID.
    private func upload(_ attachment: PendingAttachment, clientId: String,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let fileURL = engine.deps.fileStore.url(attachment.localFile)
        guard let data = try? Data(contentsOf: fileURL) else {
            throw SupportError(code: "attachment_missing", status: 400, message: "The attachment file is gone")
        }
        let request = UploadRequest(contentType: attachment.contentType, size: data.count, width: attachment.width,
                                    height: attachment.height, filename: attachment.filename)
        let created: UploadResponse = try await engine.authorized { token in
            try await engine.api.send(.post, "/v1/sdk/uploads", body: request, token: token, retry: .none)
        }
        guard let uploadURL = URL(string: created.uploadUrl) else {
            throw SupportError(code: SupportError.invalidResponse, status: 201)
        }
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue(attachment.contentType, forHTTPHeaderField: "Content-Type")
        put.setValue(engine.appID, forHTTPHeaderField: "X-Support-App")
        put.setValue("ios/\(SDKInfo.version)", forHTTPHeaderField: "X-Support-SDK")
        if uploadURL.host == engine.baseURL.host, let token = engine.deviceToken {
            put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (body, response) = try await engine.deps.transport.upload(put, body: data, progress: progress)
            guard (200..<300).contains(response.statusCode) else { throw APIClient.error(from: body, response: response) }
        } catch {
            throw APIClient.transportError(error)
        }
        return created.uploadId
    }

    private func sendViaSocket(cid: String, text: String?, attachments: [String]?) async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            pendingAcks[cid] = continuation
            guard realtime?.send(.send(cid: cid, text: text, attachments: attachments)) == true else {
                pendingAcks.removeValue(forKey: cid)?.resume(throwing: SupportError(code: SupportError.connectionFailed))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.ackTimeout * 1_000_000_000))
                self?.pendingAcks.removeValue(forKey: cid)?.resume(throwing: SupportError(code: SupportError.connectionFailed,
                                                                                         message: "No ack"))
            }
        }
    }

    private func failPendingAcks() {
        let acks = pendingAcks
        pendingAcks = [:]
        for continuation in acks.values {
            continuation.resume(throwing: SupportError(code: SupportError.connectionFailed))
        }
    }

    // MARK: - Cards

    func openCard(_ row: ChatRow) {
        guard let card = row.card else { return }
        switch card {
        case .review(let url, _):
            engine.emit(.reviewOpened)
            if engine.deps.systemIntegration { UIApplication.shared.open(url) }
        case .offer(let paywallId, _, _, let available):
            guard available, engine.isPaywallAvailable(paywallId) else { return }
            engine.emit(.paywallOpened)
            engine.settings.onPaywall?(paywallId)
        case .app(let promo):
            guard promo.state == .available, promo.appStoreId != nil || promo.url != nil else { return }
            engine.emit(.appPromoOpened)
            if engine.deps.systemIntegration { AppStoreSheet.open(appStoreId: promo.appStoreId, fallback: promo.url) }
        case .code(let code):
            guard code.state == .available, let url = code.redeemURL else { return }
            engine.emit(.codeOpened)
            if engine.deps.systemIntegration { UIApplication.shared.open(url) }
        }
        sendActionReceipt("open", for: row)
    }

    /// Copies a code card's code (allowed on any platform until it expires). Returns whether it
    /// was copied, so the card can confirm it.
    @discardableResult
    func copyCode(_ row: ChatRow) -> Bool {
        guard case .code(let code)? = row.card, code.state != .expired else { return false }
        if engine.deps.systemIntegration { UIPasteboard.general.string = code.code }
        engine.emit(.codeCopied)
        sendActionReceipt("copy", for: row)
        return true
    }

    /// `POST /v1/sdk/actions/:messageId`, fire and forget (§3.6).
    private func sendActionReceipt(_ action: String, for row: ChatRow) {
        guard let messageId = row.messageId else { return }
        Task {
            try? await engine.authorized { token in
                try await engine.api.sendVoid(.post, "/v1/sdk/actions/\(messageId)", body: ["action": action], token: token, retry: .standard)
            }
        }
    }

    // MARK: - State changes

    func configChanged() {
        let config = engine.config
        let next: Restriction
        if config?.blocked == true {
            next = .blocked
        } else if config?.verifiedOnly == true && engine.customer?.verified != true && engine.identityToken == nil {
            next = .verificationRequired
        } else if restrictionFromError == .blocked && config?.blocked == nil {
            next = .blocked
        } else if restrictionFromError == .verificationRequired && engine.identityToken == nil {
            next = .verificationRequired
        } else {
            next = .none
        }
        if next == .none { restrictionFromError = .none }
        let wasRestricted = restriction != .none
        restriction = next
        if wasRestricted && next == .none { drain() }
        rebuildRows()
    }

    func paywallsChanged() { rebuildRows() }

    /// The session was reset (logout, deletion, user switch, or a rejected device token).
    func sessionChanged(clearOutbox: Bool) {
        let wasLive = liveTask != nil || realtime != nil
        stopLive()
        cache.reset()
        hasMore = false
        loadState = .idle
        engine.deps.fileStore.remove(Self.messagesFile)
        if clearOutbox {
            drainTask?.cancel()
            drainTask = nil
            for item in outbox.items { deleteFiles(of: item) }
            outbox = Outbox()
            engine.deps.fileStore.remove(Self.outboxFile)
            engine.deps.fileStore.remove(Self.outboxFolder)
            draft = ""
            restrictionFromError = .none
        }
        configChanged()
        rebuildRows()
        if wasLive && isVisible { startLive() }
    }

    // MARK: - Persistence and rows

    private func deleteFiles(of item: PendingMessage) {
        for attachment in item.attachments { engine.deps.fileStore.remove(attachment.localFile) }
    }

    private func saveCache() { engine.deps.fileStore.save(cache.persisted, to: Self.messagesFile) }
    private func saveOutbox() { engine.deps.fileStore.save(outbox, to: Self.outboxFile) }
    private func saveAll() {
        saveCache()
        saveOutbox()
    }

    func rebuildRows() {
        let fileStore = engine.deps.fileStore
        let teamDisplay = engine.config?.teamDisplay
        let context = ChatPresentation.Context(
            customerLanguage: engine.customerLanguage,
            agentReadSeq: cache.agentReadSeq,
            showNames: teamDisplay?.showNames ?? true,
            showPhotos: teamDisplay?.showPhotos ?? true,
            uploadProgress: uploadProgress,
            isPaywallAvailable: { [engine] id in engine.isPaywallAvailable(id) },
            fileURL: { fileStore.url($0) },
            now: engine.deps.now()
        )
        let newRows = ChatPresentation.rows(messages: cache.messages, outbox: outbox.items, context: context)
        if newRows != rows { rows = newRows }
        scheduleExpiryRefresh(after: context.now)
    }

    /// Redraws the thread when the next code card expires, if that's within a day (anything later
    /// is picked up by a later rebuild).
    private func scheduleExpiryRefresh(after now: Date) {
        let next = ChatPresentation.nextExpiry(in: cache.messages, after: now)
        guard next != scheduledExpiry else { return }
        expiryTask?.cancel()
        expiryTask = nil
        scheduledExpiry = next
        guard let next, next.timeIntervalSince(now) < 86_400 else { return }
        let delay = next.timeIntervalSince(now) + 0.5
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.scheduledExpiry = nil
            self.rebuildRows()
        }
    }

    /// Replaces the conversation with sample data (previews and screenshots).
    func loadPreview(messages: [Message], pending: [PendingMessage], agentReadSeq: Int, typing: Bool) {
        cache = MessageCache(messages: messages)
        cache.agentReadSeq = agentReadSeq
        cache.customerReadSeq = messages.last?.seq ?? 0
        outbox = Outbox(items: pending)
        agentTyping = typing
        loadState = .loaded
        rebuildRows()
    }
}
