import XCTest
@testable import YapsSupport

final class OutboxTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_318_400)

    private func pending(_ id: String, text: String = "hi") -> PendingMessage {
        PendingMessage(clientId: id, text: text, attachments: [], createdAt: now)
    }

    func testEnqueueDeduplicatesByClientID() {
        var outbox = Outbox()
        XCTAssertTrue(outbox.enqueue(pending("A")))
        XCTAssertFalse(outbox.enqueue(pending("A", text: "again")))
        XCTAssertEqual(outbox.items.map(\.text), ["hi"])
    }

    func testReconcileDropsMessagesTheServerAlreadyHas() {
        var outbox = Outbox()
        outbox.enqueue(pending("A"))
        outbox.enqueue(pending("B"))
        let removed = outbox.reconcile(with: [message(id: "msg_1", seq: 1, author: .customer, clientId: "A")])
        XCTAssertEqual(removed.map(\.clientId), ["A"])
        XCTAssertEqual(outbox.items.map(\.clientId), ["B"])
    }

    func testRowsHidePendingMessagesThatWereConfirmed() {
        let context = ChatPresentation.Context(customerLanguage: "en", agentReadSeq: 0, isPaywallAvailable: { _ in false },
                                               fileURL: { URL(fileURLWithPath: $0) })
        let rows = ChatPresentation.rows(messages: [message(id: "msg_1", seq: 1, author: .customer, clientId: "A")],
                                         outbox: [pending("A"), pending("B")], context: context)
        XCTAssertEqual(rows.map(\.id), ["c:A", "c:B"])
        XCTAssertEqual(rows.map(\.delivery), [.sent, .sending(progress: nil)])
    }

    func testBackoffDoublesAndFailsAfterFiveAttempts() {
        var outbox = Outbox()
        outbox.enqueue(pending("A"))
        let error = SupportError(code: SupportError.serverError, status: 503)
        var delays: [TimeInterval] = []
        for attempt in 1...5 {
            let state = outbox.recordFailure("A", error: error, now: now, jitter: 0)
            if attempt < 5 {
                XCTAssertEqual(state, .queued)
                delays.append(outbox.item("A")!.nextAttemptAt!.timeIntervalSince(now))
            } else {
                XCTAssertEqual(state, .failed)
            }
        }
        XCTAssertEqual(delays, [1, 2, 4, 8])
        XCTAssertEqual(outbox.item("A")?.attempts, Outbox.maxAttempts)
        XCTAssertEqual(outbox.item("A")?.lastErrorCode, "server_error")
        XCTAssertNil(outbox.nextDue(now: now.addingTimeInterval(1000)))
    }

    func testRateLimitWaitsForRetryAfter() {
        var outbox = Outbox()
        outbox.enqueue(pending("A"))
        outbox.recordFailure("A", error: SupportError(code: SupportError.rateLimited, status: 429, retryAfter: 5), now: now, jitter: 0)
        XCTAssertEqual(outbox.item("A")?.nextAttemptAt, now.addingTimeInterval(5))
        XCTAssertNil(outbox.nextDue(now: now.addingTimeInterval(4.9)))
        XCTAssertEqual(outbox.nextDue(now: now.addingTimeInterval(5))?.clientId, "A")
    }

    func testDefinitiveRejectionFailsImmediately() {
        var outbox = Outbox()
        outbox.enqueue(pending("A"))
        let state = outbox.recordFailure("A", error: SupportError(code: SupportError.tooLarge, status: 413), now: now)
        XCTAssertEqual(state, .failed)
        XCTAssertEqual(outbox.item("A")?.attempts, 1)
    }

    func testMessagesAreSentInOrder() {
        var outbox = Outbox()
        outbox.enqueue(pending("A"))
        outbox.enqueue(pending("B"))
        XCTAssertEqual(outbox.nextDue(now: now)?.clientId, "A")
        outbox.recordFailure("A", error: SupportError(code: SupportError.connectionFailed), now: now, jitter: 0)
        XCTAssertNil(outbox.nextDue(now: now), "B waits behind A's retry")
        XCTAssertEqual(outbox.nextWakeUp(), now.addingTimeInterval(1))
        outbox.markFailed("A", code: "too_large")
        XCTAssertEqual(outbox.nextDue(now: now)?.clientId, "B", "A failed message no longer blocks the queue")
    }

    func testManualRetryResetsTheBudget() {
        var outbox = Outbox()
        outbox.enqueue(pending("A"))
        for _ in 0..<5 { outbox.recordFailure("A", error: SupportError(code: SupportError.serverError, status: 500), now: now) }
        XCTAssertEqual(outbox.item("A")?.state, .failed)
        outbox.retry("A", now: now)
        XCTAssertEqual(outbox.item("A")?.state, .queued)
        XCTAssertEqual(outbox.item("A")?.attempts, 0)
        XCTAssertEqual(outbox.nextDue(now: now)?.clientId, "A")
    }

    func testInterruptedSendsResumeAfterRelaunch() throws {
        var outbox = Outbox()
        outbox.enqueue(pending("A"))
        outbox.markSending("A")
        XCTAssertNil(outbox.nextDue(now: now))
        let data = try WireJSON.encoder().encode(outbox)
        var restored = try WireJSON.decoder().decode(Outbox.self, from: data)
        restored.recoverInterrupted()
        XCTAssertEqual(restored.nextDue(now: now)?.clientId, "A")
    }

    func testUploadIDsArePersistedSoRetriesDontReupload() {
        var outbox = Outbox()
        var item = pending("A")
        item.attachments = [PendingAttachment(localFile: "outbox-files/A-0.jpg", kind: .image, contentType: "image/jpeg", size: 10)]
        outbox.enqueue(item)
        outbox.setUploadID("upl_1", clientId: "A", attachmentIndex: 0)
        XCTAssertEqual(outbox.item("A")?.attachments.first?.uploadId, "upl_1")
        XCTAssertTrue(outbox.item("A")!.hasImages)
    }

    func testBackoffSchedules() {
        XCTAssertEqual((0..<8).map { Backoff.rest(attempt: $0, jitter: 0) }, [1, 2, 4, 8, 16, 32, 60, 60])
        XCTAssertEqual((0..<8).map { Backoff.socket(attempt: $0, jitter: 0) }, [1, 2, 4, 8, 16, 30, 30, 30])
        for _ in 0..<100 {
            let delay = Backoff.socket(attempt: 2)
            XCTAssertGreaterThanOrEqual(delay, 3.2)
            XCTAssertLessThanOrEqual(delay, 4.8)
        }
    }

    func testMessageCacheMergesSortsAndCaps() {
        var cache = MessageCache()
        cache.merge([message(id: "b", seq: 2), message(id: "a", seq: 1)])
        cache.merge([message(id: "b", seq: 2, text: "edited")])
        XCTAssertEqual(cache.messages.map(\.id), ["a", "b"])
        XCTAssertEqual(cache.messages.last?.text, "edited")
        for seq in 3...260 { cache.merge([message(id: "m\(seq)", seq: seq)]) }
        let persisted = cache.persisted
        XCTAssertEqual(persisted.messages.count, MessageCache.limit)
        XCTAssertEqual(persisted.messages.last?.seq, 260)
        XCTAssertTrue(persisted.hasMore)
    }

    func testStaleCacheIsReplacedWhenTheLatestPageDoesNotOverlap() {
        var cache = MessageCache(messages: [message(id: "a", seq: 1), message(id: "b", seq: 2)])
        cache.applyLatestPage([message(id: "x", seq: 90), message(id: "y", seq: 91)], hasMore: true)
        XCTAssertEqual(cache.messages.map(\.id), ["x", "y"])
        XCTAssertTrue(cache.hasMore)
        cache.applyLatestPage([message(id: "y", seq: 91), message(id: "z", seq: 92)], hasMore: true)
        XCTAssertEqual(cache.messages.map(\.id), ["x", "y", "z"])
    }
}

/// The send pipeline end to end against a mock server.
@MainActor
final class SendPipelineTests: XCTestCase {
    private var harness: EngineHarness!

    override func setUp() async throws {
        harness = EngineHarness()
        harness.stubRegister()
    }

    override func tearDown() async throws {
        harness.cleanUp()
    }

    func testRetriesWithTheSameClientIDUntilTheServerAccepts() async throws {
        let chat = harness.engine.chat
        try await harness.engine.ensureRegistered()
        XCTAssertTrue(chat.send(text: "  is there a dark mode?  ", attachments: []))
        XCTAssertEqual(chat.draft, "")
        // Delivery starts on the next main-actor turn, so the server script can echo the client ID.
        let clientId = try XCTUnwrap(chat.outbox.items.first?.clientId)
        harness.transport.on("POST", "/v1/sdk/messages", status: 503, json: ["error": ["code": "server_error", "message": "x"]])
        harness.transport.on("POST", "/v1/sdk/messages", status: 503, json: ["error": ["code": "server_error", "message": "x"]])
        harness.transport.on("POST", "/v1/sdk/messages", status: 201, json: ["message": messageJSON(id: "msg_1", seq: 1, clientId: clientId, text: "is there a dark mode?")])

        await waitUntil { chat.outbox.isEmpty && chat.cache.messages.count == 1 }
        let sends = harness.transport.requests("POST", "/v1/sdk/messages")
        XCTAssertGreaterThanOrEqual(sends.count, 3)
        XCTAssertTrue(sends.allSatisfy { $0.json?["clientId"] as? String == clientId }, "Every retry reuses the client ID")
        XCTAssertEqual(sends.last?.json?["text"] as? String, "is there a dark mode?", "Text is trimmed")
        XCTAssertEqual(sends.last?.header("Authorization"), "Bearer dt_reg_1_secret")
        XCTAssertTrue(harness.clock.sleeps.contains { $0 >= 0.8 && $0 <= 1.2 }, "First retry waits about 1 s")
        XCTAssertEqual(chat.rows.map(\.id), ["c:\(clientId)"])
        XCTAssertEqual(chat.rows.first?.delivery, .sent)
        XCTAssertEqual(harness.events.filter { $0 == .messageSent }.count, 1)
    }

    func testMarksFailedAfterFiveAttemptsAndRetrySucceeds() async throws {
        harness.transport.on("POST", "/v1/sdk/messages", status: 500, json: ["error": ["code": "server_error", "message": "x"]])
        try await harness.engine.ensureRegistered()
        let chat = harness.engine.chat
        chat.send(text: "hello", attachments: [])
        await waitUntil { chat.outbox.items.first?.state == .failed }
        XCTAssertEqual(harness.transport.requests("POST", "/v1/sdk/messages").count, 5)
        guard case .failed? = chat.rows.first?.delivery else { return XCTFail("Expected a failed row") }

        let clientId = try XCTUnwrap(chat.outbox.items.first?.clientId)
        harness.transport.reset("POST", "/v1/sdk/messages")
        harness.transport.on("POST", "/v1/sdk/messages", status: 201, json: ["message": messageJSON(id: "msg_1", seq: 1, clientId: clientId)])
        chat.retry(clientId: clientId)
        await waitUntil { chat.outbox.isEmpty }
        XCTAssertEqual(chat.rows.first?.delivery, .sent)
    }

    func testBlockedSendShowsTheNoticeAndKeepsTheMessage() async throws {
        harness.transport.on("POST", "/v1/sdk/messages", status: 403, json: ["error": ["code": "blocked", "message": "x"]])
        try await harness.engine.ensureRegistered()
        let chat = harness.engine.chat
        chat.send(text: "hello", attachments: [])
        await waitUntil { chat.restriction == .blocked }
        XCTAssertEqual(chat.outbox.items.first?.state, .failed)
        XCTAssertEqual(chat.validate(text: "more", attachments: []), .restricted)
    }

    func testVerifiedOnlyAppsRequireSignIn() async throws {
        harness.transport.reset("POST", "/v1/sdk/register")
        harness.stubRegister(config: ["verifiedOnly": true])
        try await harness.engine.ensureRegistered()
        XCTAssertEqual(harness.engine.chat.restriction, .verificationRequired)
    }

    func testValidation() {
        let chat = harness.engine.chat
        XCTAssertEqual(chat.validate(text: "   ", attachments: []), .empty)
        XCTAssertEqual(chat.validate(text: String(repeating: "a", count: 4000), attachments: []), .ok)
        XCTAssertEqual(chat.validate(text: String(repeating: "a", count: 4001), attachments: []), .tooLong)
        XCTAssertEqual(chat.validate(text: String(repeating: "🐓", count: 2001), attachments: []), .tooLong, "Counted in UTF-16 units")
        let image = DraftAttachment(kind: .image, data: Data([1]), contentType: "image/jpeg", filename: "a.jpg")
        XCTAssertEqual(chat.validate(text: "", attachments: [image]), .ok, "Attachments alone are allowed")
        XCTAssertEqual(chat.validate(text: "", attachments: Array(repeating: image, count: 6)), .tooManyAttachments)
    }

    func testImageUploadFlow() async throws {
        harness.transport.on("POST", "/v1/sdk/uploads", status: 201,
                             json: ["uploadId": "upl_1", "uploadUrl": "https://support.test/v1/uploads/upl_1?sig=abc", "expiresAt": "2026-10-30T10:41:00.000Z"])
        harness.transport.on("PUT", "/v1/uploads/upl_1", json: ["attachment": ["id": "upl_1", "kind": "image", "contentType": "image/jpeg",
                                                                                "url": "https://support.test/f/upl_1", "size": 3]])
        try await harness.engine.ensureRegistered()
        let chat = harness.engine.chat
        let image = DraftAttachment(kind: .image, data: Data([0xFF, 0xD8, 0xFF]), contentType: "image/jpeg", filename: "IMG_1.jpg",
                                    width: 1536, height: 2048)
        chat.send(text: "", attachments: [image])
        let clientId = try XCTUnwrap(chat.outbox.items.first?.clientId)
        harness.transport.on("POST", "/v1/sdk/messages", status: 201, json: ["message": messageJSON(id: "msg_3", seq: 3, clientId: clientId, text: "")])
        await waitUntil { chat.outbox.isEmpty }

        let create = try XCTUnwrap(harness.transport.requests("POST", "/v1/sdk/uploads").first?.json)
        XCTAssertEqual(create["contentType"] as? String, "image/jpeg")
        XCTAssertEqual(create["size"] as? Int, 3)
        XCTAssertEqual(create["width"] as? Int, 1536)
        XCTAssertEqual(create["filename"] as? String, "IMG_1.jpg")
        let put = try XCTUnwrap(harness.transport.requests("PUT", "/v1/uploads/upl_1").first)
        XCTAssertEqual(put.body, Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(put.header("Content-Type"), "image/jpeg")
        XCTAssertEqual(put.query("sig"), "abc")
        let send = try XCTUnwrap(harness.transport.requests("POST", "/v1/sdk/messages").first?.json)
        XCTAssertEqual(send["attachments"] as? [String], ["upl_1"])
        XCTAssertNil(send["text"], "Empty text is omitted")
        XCTAssertEqual(harness.events, [.messageSent, .imageSent])
    }

    func testDraftIsPersisted() {
        let chat = harness.engine.chat
        chat.draft = "half-written question"
        let relaunched = harness.makeEngine()
        XCTAssertEqual(relaunched.chat.draft, "half-written question")
    }

    func testOutboxSurvivesRelaunch() async throws {
        let chat = harness.engine.chat
        // Not registered and registration fails, so the message stays queued.
        harness.transport.reset("POST", "/v1/sdk/register")
        harness.transport.on("POST", "/v1/sdk/register", status: 500, json: ["error": ["code": "server_error", "message": "x"]])
        chat.send(text: "offline message", attachments: [])
        await waitUntil { chat.outbox.items.first?.attempts ?? 0 >= 1 }
        chat.shutdown()
        let relaunched = harness.makeEngine()
        XCTAssertEqual(relaunched.chat.outbox.items.map(\.text), ["offline message"])
        XCTAssertEqual(relaunched.chat.rows.first?.text, "offline message")
    }

    func testLoadEarlierUsesBefore() async throws {
        harness.transport.on("GET", "/v1/sdk/conversation", json: [
            "conversation": ["id": "cnv_1", "status": "open", "lastSeq": 52, "customerReadSeq": 52, "agentReadSeq": 52, "unread": 0, "createdAt": "2026-10-30T09:41:00.000Z"],
            "messages": (3...52).map { messageJSON(id: "msg_\($0)", seq: $0, author: "agent") }, "hasMore": true,
        ])
        harness.transport.on("GET", "/v1/sdk/messages", json: ["messages": [messageJSON(id: "msg_1", seq: 1), messageJSON(id: "msg_2", seq: 2)], "hasMore": false])
        let chat = harness.engine.chat
        await chat.loadLatest()
        XCTAssertTrue(chat.hasMore)
        XCTAssertEqual(chat.rows.count, 50)
        await chat.loadEarlier()
        let request = try XCTUnwrap(harness.transport.requests("GET", "/v1/sdk/messages").first)
        XCTAssertEqual(request.query("before"), "3")
        XCTAssertEqual(request.query("limit"), "50")
        XCTAssertEqual(chat.rows.count, 52)
        XCTAssertEqual(chat.rows.first?.messageId, "msg_1")
        XCTAssertFalse(chat.hasMore)
    }

    func testSocketFramesUpdateTheThread() async throws {
        harness.settings.languageOverride = "es"
        let chat = harness.engine.chat
        chat.handle(.message(message(id: "msg_2", seq: 2, author: .agent, text: "Yes!")))
        chat.handle(.state(agentTyping: true, agentReadSeq: nil, customerReadSeq: nil))
        XCTAssertTrue(chat.agentTyping)
        chat.handle(.message(message(id: "msg_3", seq: 3, author: .agent, text: "More")))
        XCTAssertFalse(chat.agentTyping, "A reply ends the typing indicator")
        var updated = message(id: "msg_2", seq: 2, author: .agent, text: "Yes!")
        updated.translation = Translation(language: "es", text: "¡Sí!")
        chat.handle(.update(updated))
        XCTAssertEqual(chat.rows.map(\.text), ["¡Sí!", "More"], "upd replaces by id and the Spanish translation is shown")
    }

    func testOfferCardTapCallsOnPaywallOnlyWhenAvailable() async throws {
        harness.transport.on("POST", "/v1/sdk/actions/msg_4", status: 204)
        try await harness.engine.ensureRegistered()
        var opened: [String] = []
        harness.settings.onPaywall = { opened.append($0) }
        harness.settings.paywalls = [SupportPaywall(id: "yearly_offer", title: "Yearly 40% off")]
        harness.engine.refreshPaywalls()
        let chat = harness.engine.chat
        chat.handle(.message(try Fixtures.decode(Message.self, "message-offer-card.json")))
        let row = try XCTUnwrap(chat.rows.first)
        XCTAssertEqual(row.card, .offer(paywallId: "yearly_offer", label: "View offer", title: "Yearly 40% off", available: true))
        chat.openCard(row)
        XCTAssertEqual(opened, ["yearly_offer"])
        XCTAssertTrue(harness.events.contains(.paywallOpened))
        await waitUntil { !harness.transport.requests("POST", "/v1/sdk/actions/msg_4").isEmpty }
        XCTAssertEqual(harness.transport.requests("POST", "/v1/sdk/actions/msg_4").first?.json?["action"] as? String, "open")

        harness.settings.paywalls = []
        harness.engine.refreshPaywalls()
        let unavailable = try XCTUnwrap(chat.rows.first)
        guard case .offer(_, _, _, false)? = unavailable.card else { return XCTFail("Expected an unavailable offer") }
        chat.openCard(unavailable)
        XCTAssertEqual(opened, ["yearly_offer"], "Unavailable offers do nothing")
    }

    func testReviewCardEmitsReviewOpened() async throws {
        let chat = harness.engine.chat
        chat.handle(.message(try Fixtures.decode(Message.self, "message-review-card.json")))
        chat.openCard(try XCTUnwrap(chat.rows.first))
        XCTAssertEqual(harness.events, [.reviewOpened])
    }
}
