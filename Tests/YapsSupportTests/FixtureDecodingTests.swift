import XCTest
@testable import YapsSupport

/// Conformance with `protocol/fixtures` (see its README).
final class FixtureDecodingTests: XCTestCase {
    private func context(language: String = "en", paywalls: Set<String> = []) -> ChatPresentation.Context {
        ChatPresentation.Context(customerLanguage: language, agentReadSeq: 0,
                                 isPaywallAvailable: { paywalls.contains($0) },
                                 fileURL: { URL(fileURLWithPath: "/tmp/\($0)") })
    }

    func testEveryFixtureIsBundled() {
        let expected = ["appearance.json", "conversation-response.json", "error-rate-limited.json",
                        "message-agent-translated.json", "message-app-card.json", "message-code-card-other-platform.json",
                        "message-code-card.json", "message-image.json", "message-offer-card.json",
                        "message-review-card.json", "message-text.json", "message-unknown-card.json",
                        "push-apns.json", "push-fcm-data.json", "register-response.json", "server-frames.jsonl"]
        XCTAssertEqual(Set(Fixtures.names), Set(expected))
    }

    /// The test copies must match `protocol/fixtures`, the source of truth, whenever the repo is
    /// readable from the test process.
    func testBundledFixturesMatchProtocolSource() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: source.path) else {
            throw XCTSkip("protocol/fixtures isn't readable from the simulator")
        }
        let sourceFixtures = Set(names.filter { $0.hasSuffix(".json") || $0.hasSuffix(".jsonl") })
        XCTAssertEqual(sourceFixtures.subtracting(Fixtures.names), [],
                       "New fixtures in protocol/fixtures; copy them into Tests/YapsSupportTests/Fixtures")
        XCTAssertEqual(Set(Fixtures.names).subtracting(sourceFixtures), [],
                       "Bundled fixtures that protocol/fixtures no longer has")
        for name in sourceFixtures.intersection(Fixtures.names).sorted() {
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(name)), try Fixtures.data(name),
                           "\(name) is out of date; copy protocol/fixtures into Tests/YapsSupportTests/Fixtures")
        }
    }

    func testEveryMessageFixtureDecodes() throws {
        let messageFixtures = Fixtures.names.filter { $0.hasPrefix("message-") }
        XCTAssertEqual(messageFixtures.count, 9)
        for name in messageFixtures {
            let message = try Fixtures.decode(Message.self, name)
            XCTAssertFalse(message.id.isEmpty, name)
            XCTAssertEqual(message.conversationId, "cnv_1", name)
            XCTAssertTrue(message.isDisplayable, name)
        }
    }

    func testTextMessage() throws {
        let message = try Fixtures.decode(Message.self, "message-text.json")
        XCTAssertEqual(message.id, "msg_1")
        XCTAssertEqual(message.seq, 1)
        XCTAssertEqual(message.clientId, "01JD8Z6Q0000000000000000AA")
        XCTAssertEqual(message.author.type, .customer)
        XCTAssertEqual(message.kind, .text)
        XCTAssertNil(message.translation)
        XCTAssertNil(message.card)
        XCTAssertEqual(message.createdAt, WireJSON.parseDate("2026-10-30T09:41:00.000Z"))
    }

    func testUnknownFieldsAreIgnored() throws {
        let message = try Fixtures.decode(Message.self, "message-agent-translated.json")
        XCTAssertEqual(message.author.name, "Frederick")
        XCTAssertEqual(message.author.avatarUrl, "https://support.yaps.ai/v1/files/avatars/usr_3.png")
        XCTAssertEqual(message.status, .read)
        XCTAssertEqual(message.translation, Translation(language: "es", text: "¡Sí! Ajustes → Apariencia → Oscuro."))
    }

    func testUnknownEnumValuesAndExtraFieldsDecode() throws {
        let json = #"""
        {"id":"msg_7","conversationId":"cnv_1","seq":7,"author":{"type":"robot","mood":"happy"},"kind":"poll",
         "text":"Pick one","attachments":[{"id":"upl_9","kind":"video","contentType":"video/mp4","url":"https://x/y","size":1,"codec":"h265"}],
         "createdAt":"2026-10-30T09:41:00Z","status":"teleported","reactions":[{"emoji":"🐓"}]}
        """#
        let message = try WireJSON.decoder().decode(Message.self, from: Data(json.utf8))
        XCTAssertEqual(message.author.type, .unknown)
        XCTAssertEqual(message.kind, .unknown)
        XCTAssertEqual(message.status, .unknown)
        XCTAssertEqual(message.attachments.first?.kind, .unknown)
        XCTAssertTrue(message.isDisplayable, "Unknown kinds with text are shown as text")
    }

    func testEventMessagesAreNeverShown() throws {
        var json = try JSONSerialization.jsonObject(with: Fixtures.data("message-text.json")) as! [String: Any]
        json["kind"] = "event"
        let message = try WireJSON.decoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(message.isDisplayable)
        var cache = MessageCache()
        cache.merge([message])
        XCTAssertTrue(cache.messages.isEmpty)
    }

    func testUnknownCardRendersAsPlainText() throws {
        let message = try Fixtures.decode(Message.self, "message-unknown-card.json")
        XCTAssertEqual(message.card?.type, "calendar")
        XCTAssertEqual(message.card?.known, .unknown)
        let row = ChatPresentation.row(for: message, context: context())
        XCTAssertNil(row.card)
        XCTAssertEqual(row.text, "Book a call with us")
    }

    func testReviewCard() throws {
        let message = try Fixtures.decode(Message.self, "message-review-card.json")
        let row = ChatPresentation.row(for: message, context: context())
        XCTAssertEqual(row.card, .review(url: URL(string: "https://apps.apple.com/app/id6450000000?action=write-review")!,
                                         label: "Rate on the App Store"))
        XCTAssertEqual(row.authorName, "Frederick")
    }

    func testOfferCardAvailability() throws {
        let message = try Fixtures.decode(Message.self, "message-offer-card.json")
        let available = ChatPresentation.row(for: message, context: context(paywalls: ["yearly_offer"]))
        XCTAssertEqual(available.card, .offer(paywallId: "yearly_offer", label: "View offer", title: "Yearly 40% off", available: true))
        let unavailable = ChatPresentation.row(for: message, context: context(paywalls: []))
        XCTAssertEqual(unavailable.card, .offer(paywallId: "yearly_offer", label: "View offer", title: "Yearly 40% off", available: false))
        XCTAssertEqual(unavailable.text, "Yearly is 40% off right now, want it?")
    }

    func testImageMessage() throws {
        let message = try Fixtures.decode(Message.self, "message-image.json")
        XCTAssertEqual(message.attachments.count, 1)
        let attachment = try XCTUnwrap(message.attachments.first)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.width, 1536)
        XCTAssertEqual(attachment.height, 2048)
        XCTAssertEqual(attachment.size, 183022)
        let row = ChatPresentation.row(for: message, context: context())
        XCTAssertTrue(row.isOutgoing)
        XCTAssertEqual(row.text, "")
        guard case .remoteImage(_, let thumb, let full, 1536, 2048)? = row.attachments.first else {
            return XCTFail("Expected a remote image")
        }
        XCTAssertEqual(thumb?.absoluteString, attachment.thumbnailUrl)
        XCTAssertEqual(full.absoluteString, attachment.url)
    }

    func testConversationResponse() throws {
        let response = try Fixtures.decode(ConversationResponse.self, "conversation-response.json")
        XCTAssertEqual(response.conversation?.id, "cnv_1")
        XCTAssertEqual(response.conversation?.lastSeq, 2)
        XCTAssertEqual(response.conversation?.unread, 1)
        XCTAssertEqual(response.messages.map(\.id), ["msg_1", "msg_2"])
        XCTAssertFalse(response.hasMore)
    }

    func testMessageListSkipsBrokenEntries() throws {
        let json = #"{"messages":[{"id":"bad"},{"id":"msg_1","conversationId":"cnv_1","seq":1,"author":{"type":"agent"},"kind":"text","text":"ok","attachments":[],"createdAt":"2026-10-30T09:41:00.000Z"}],"hasMore":true}"#
        let response = try WireJSON.decoder().decode(MessagesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.messages.map(\.id), ["msg_1"])
        XCTAssertTrue(response.hasMore)
    }

    func testRegisterResponse() throws {
        let response = try Fixtures.decode(RegisterResponse.self, "register-response.json")
        XCTAssertEqual(response.deviceToken, "dt_reg_8f2k_example")
        XCTAssertEqual(response.registrationId, "reg_8f2k")
        XCTAssertEqual(response.customer.verified, false)
        XCTAssertEqual(response.config.appName, "Clucky")
        XCTAssertEqual(response.config.trackedEvents, ["paywall_declined"])
        XCTAssertEqual(response.config.translation?.customerLanguage, "es")
        XCTAssertEqual(response.config.pollIntervalSeconds, 60)
        XCTAssertEqual(response.config.appearanceEtag, #"W/"a1""#)
        XCTAssertTrue(response.config.allowsImages)
    }

    func testAppearanceFixture() throws {
        let appearance = try Fixtures.decode(RemoteAppearance.self, "appearance.json")
        XCTAssertEqual(appearance.colors?.accent, ColorPair(light: "#FF7A45", dark: "#FF8A5B"))
        XCTAssertEqual(appearance.title?["es"], "Soporte de Clucky")
        XCTAssertEqual(appearance.fontStyle, "rounded")
        XCTAssertEqual(appearance.cornerStyle, "round")
        XCTAssertEqual(appearance.showCloseButton, true)
        XCTAssertNil(appearance.welcomeIconUrl)
    }

    func testRateLimitedErrorEnvelope() throws {
        let response = HTTPURLResponse(url: URL(string: "https://support.test")!, statusCode: 429, httpVersion: nil, headerFields: nil)!
        let error = APIClient.error(from: try Fixtures.data("error-rate-limited.json"), response: response)
        XCTAssertEqual(error.code, SupportError.rateLimited)
        XCTAssertEqual(error.status, 429)
        XCTAssertEqual(error.retryAfter, 5)
        XCTAssertTrue(error.isRetryable)
        XCTAssertFalse(error.isPermanentRejection)
    }

    func testErrorWithoutEnvelope() {
        let response = HTTPURLResponse(url: URL(string: "https://support.test")!, statusCode: 503, httpVersion: nil,
                                       headerFields: ["Retry-After": "7"])!
        let error = APIClient.error(from: Data("<html>".utf8), response: response)
        XCTAssertEqual(error.code, SupportError.serverError)
        XCTAssertEqual(error.retryAfter, 7)
        XCTAssertTrue(error.isRetryable)
    }

    func testServerFramesDecodeAndUnknownFramesAreSkipped() throws {
        let lines = String(decoding: try Fixtures.data("server-frames.jsonl"), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 8)
        let frames = try lines.map { try ServerFrame.decode(Data($0.utf8)) }
        guard case .welcome("cnv_1", 2) = frames[0] else { return XCTFail("welcome") }
        guard case .message(let message) = frames[1], message.id == "msg_2" else { return XCTFail("msg") }
        guard case .ack("01JD8Z6Q0000000000000000AA", let acked) = frames[2], acked.clientId == "01JD8Z6Q0000000000000000AA" else {
            return XCTFail("ack")
        }
        XCTAssertEqual(frames[3], .state(agentTyping: true, agentReadSeq: nil, customerReadSeq: nil))
        XCTAssertEqual(frames[4], .state(agentTyping: nil, agentReadSeq: 1, customerReadSeq: nil))
        XCTAssertEqual(frames[5], .error(code: "rate_limited", cid: "01JD8Z6Q0000000000000000AC", message: nil))
        XCTAssertEqual(frames[6], .pong)
        XCTAssertEqual(frames[7], .unknown("some_future_frame"))
    }

    func testFramesIgnoreUnknownFields() throws {
        let frame = try ServerFrame.decode(Data(#"{"t":"state","agentTyping":false,"mood":"calm","v":2}"#.utf8))
        XCTAssertEqual(frame, .state(agentTyping: false, agentReadSeq: nil, customerReadSeq: nil))
        let update = try ServerFrame.decode(Data(#"{"t":"upd","extra":[1,2],"m":{"id":"msg_2","conversationId":"cnv_1","seq":2,"author":{"type":"agent"},"kind":"text","text":"Yes!","attachments":[],"createdAt":"2026-10-30T09:42:10.000Z","translation":{"language":"es","text":"¡Sí!"}}}"#.utf8))
        guard case .update(let message) = update else { return XCTFail("upd") }
        XCTAssertEqual(message.translation?.text, "¡Sí!")
    }

    @MainActor
    func testChatControllerIgnoresUnknownFrames() {
        let harness = EngineHarness()
        defer { harness.cleanUp() }
        let chat = harness.engine.chat
        let before = chat.rows
        chat.handle(.unknown("some_future_frame"))
        chat.handle(.pong)
        XCTAssertEqual(chat.rows, before)
    }

    func testClientFramesEncode() throws {
        func object(_ frame: ClientFrame) throws -> NSDictionary {
            try JSONSerialization.jsonObject(with: frame.encoded()) as! NSDictionary
        }
        XCTAssertEqual(try object(.hello(after: 2)), ["t": "hello", "after": 2])
        XCTAssertEqual(try object(.send(cid: "01AB", text: "hi", attachments: ["upl_1"])), ["t": "send", "cid": "01AB", "text": "hi", "att": ["upl_1"]])
        XCTAssertEqual(try object(.send(cid: "01AB", text: nil, attachments: nil)), ["t": "send", "cid": "01AB"])
        XCTAssertEqual(try object(.read(seq: 9)), ["t": "read", "seq": 9])
        XCTAssertEqual(try object(.typing(on: true)), ["t": "typing", "on": true])
        XCTAssertEqual(try object(.ping), ["t": "ping"])
    }

    func testDeviceUpdateEncodesPushRemovalAsNull() throws {
        var request = DeviceUpdateRequest()
        request.push = .remove
        let json = String(decoding: try WireJSON.encoder().encode(request), as: UTF8.self)
        XCTAssertEqual(json, #"{"push":null}"#)
        request.push = .set(PushInput(token: "ab", provider: "apns", environment: "sandbox"))
        request.badgeEnabled = false
        let set = String(decoding: try WireJSON.encoder().encode(request), as: UTF8.self)
        XCTAssertEqual(set, #"{"badgeEnabled":false,"push":{"environment":"sandbox","provider":"apns","token":"ab"}}"#)
    }

    func testDatesRoundTrip() throws {
        let message = try Fixtures.decode(Message.self, "message-text.json")
        let encoded = try WireJSON.encoder().encode(message)
        let decoded = try WireJSON.decoder().decode(Message.self, from: encoded)
        XCTAssertEqual(decoded, message)
        XCTAssertNotNil(WireJSON.parseDate("2026-10-30T09:41:00Z"))
    }
}
