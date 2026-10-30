import XCTest
@testable import YapsSupport

/// App promo and code cards (§5): decoding, which state each card renders in, and the events and
/// action receipts their buttons fire.
final class PromoCardPresentationTests: XCTestCase {
    /// Before the code fixtures' `expiresAt` (2026-12-31T23:59:59Z).
    private let beforeExpiry = WireJSON.parseDate("2026-10-30T10:00:00.000Z")!

    private func context(now: Date? = nil) -> ChatPresentation.Context {
        ChatPresentation.Context(customerLanguage: "en", agentReadSeq: 0, isPaywallAvailable: { _ in false },
                                 fileURL: { URL(fileURLWithPath: "/tmp/\($0)") }, now: now ?? beforeExpiry)
    }

    /// A fixture with its card fields replaced (`NSNull()` removes one).
    private func fixture(_ name: String, card changes: [String: Any]) throws -> Message {
        var json = try JSONSerialization.jsonObject(with: Fixtures.data(name)) as! [String: Any]
        var card = json["card"] as! [String: Any]
        for (key, value) in changes {
            if value is NSNull { card.removeValue(forKey: key) } else { card[key] = value }
        }
        json["card"] = card
        return try WireJSON.decoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: Decoding

    func testAppCardFixtureDecodes() throws {
        let message = try Fixtures.decode(Message.self, "message-app-card.json")
        let card = try XCTUnwrap(message.card)
        XCTAssertEqual(card.known, .app)
        XCTAssertEqual(card.title, "Stacked")
        XCTAssertEqual(card.body, "Flashcards that plan your revision for you.")
        XCTAssertEqual(card.buttonLabel, "Get it")
        XCTAssertEqual(card.iconUrl, "https://support.yaps.ai/v1/files/icons/app_2.png")
        XCTAssertEqual(card.promotedAppId, "app_2")
        XCTAssertEqual(card.appStoreId, "6450000001")
        XCTAssertEqual(card.url, "https://apps.apple.com/app/id6450000001")
        XCTAssertEqual(card.installed, false)
        XCTAssertEqual(card.available, true)
        XCTAssertNil(card.openedAt)
    }

    func testCodeCardFixtureDecodes() throws {
        let message = try Fixtures.decode(Message.self, "message-code-card.json")
        let card = try XCTUnwrap(message.card)
        XCTAssertEqual(card.known, .code)
        XCTAssertEqual(card.title, "Student discount")
        XCTAssertEqual(card.body, "20% off yearly for students.")
        XCTAssertEqual(card.code, "STUDENT20")
        XCTAssertEqual(card.campaignId, "cmp_1")
        XCTAssertEqual(card.platform, "ios")
        XCTAssertEqual(card.buttonLabel, "Redeem")
        XCTAssertEqual(card.url, "https://apps.apple.com/redeem?ctx=offercodes&id=6450000000&code=STUDENT20")
        XCTAssertEqual(card.expiresAt, "2026-12-31T23:59:59.000Z")
        XCTAssertEqual(card.expiryDate, WireJSON.parseDate("2026-12-31T23:59:59Z"))
        XCTAssertEqual(card.available, true)
    }

    func testOtherPlatformCodeCardFixtureDecodes() throws {
        let message = try Fixtures.decode(Message.self, "message-code-card-other-platform.json")
        let card = try XCTUnwrap(message.card)
        XCTAssertEqual(card.known, .code)
        XCTAssertEqual(card.code, "STUDENT20")
        XCTAssertEqual(card.available, false)
        XCTAssertNil(card.url)
        XCTAssertNil(card.body)
        XCTAssertNil(card.expiresAt)
    }

    func testMalformedExpiryKeepsTheCard() throws {
        let message = try fixture("message-code-card.json", card: ["expiresAt": "soon"])
        XCTAssertEqual(message.card?.code, "STUDENT20")
        XCTAssertNil(message.card?.expiryDate)
    }

    // MARK: App promo states

    func testAvailableAppPromo() throws {
        let row = ChatPresentation.row(for: try Fixtures.decode(Message.self, "message-app-card.json"), context: context())
        XCTAssertEqual(row.card, .app(ChatRow.AppPromo(
            title: "Stacked", body: "Flashcards that plan your revision for you.",
            iconURL: URL(string: "https://support.yaps.ai/v1/files/icons/app_2.png"), appStoreId: "6450000001",
            url: URL(string: "https://apps.apple.com/app/id6450000001"), label: "Get it", state: .available)))
        XCTAssertEqual(row.text, "Since you're studying, you might like our flashcard app too.")
    }

    func testInstalledAppPromoHasNoButton() throws {
        let installed = try fixture("message-app-card.json", card: ["installed": true])
        guard case .app(let promo)? = ChatPresentation.row(for: installed, context: context()).card else {
            return XCTFail("Expected an app card")
        }
        XCTAssertEqual(promo.state, .installed)
        // Installed wins even when the server has no store link for this platform.
        let installedElsewhere = try fixture("message-app-card.json", card: ["installed": true, "available": false])
        guard case .app(let other)? = ChatPresentation.row(for: installedElsewhere, context: context()).card else {
            return XCTFail("Expected an app card")
        }
        XCTAssertEqual(other.state, .installed)
    }

    func testUnavailableAppPromoRendersAsText() throws {
        let message = try fixture("message-app-card.json", card: ["available": false, "url": NSNull(), "appStoreId": NSNull()])
        let row = ChatPresentation.row(for: message, context: context())
        XCTAssertNil(row.card)
        XCTAssertEqual(row.text, "Since you're studying, you might like our flashcard app too.")
    }

    func testAppPromoWithoutTextFallsBackToItsTitle() throws {
        var message = try fixture("message-app-card.json", card: ["available": false])
        message.text = ""
        XCTAssertEqual(ChatPresentation.row(for: message, context: context()).text, "Stacked")
    }

    func testAppPromoWithoutStoreIDFallsBackToTheURL() throws {
        let message = try fixture("message-app-card.json", card: ["appStoreId": "not-a-number"])
        guard case .app(let promo)? = ChatPresentation.row(for: message, context: context()).card else {
            return XCTFail("Expected an app card")
        }
        XCTAssertNil(promo.appStoreId)
        XCTAssertEqual(promo.url, URL(string: "https://apps.apple.com/app/id6450000001"))
        XCTAssertEqual(promo.state, .available)
    }

    // MARK: Code states

    func testAvailableCode() throws {
        let row = ChatPresentation.row(for: try Fixtures.decode(Message.self, "message-code-card.json"), context: context())
        XCTAssertEqual(row.card, .code(ChatRow.PromoCode(
            code: "STUDENT20", title: "Student discount", body: "20% off yearly for students.", label: "Redeem",
            redeemURL: URL(string: "https://apps.apple.com/redeem?ctx=offercodes&id=6450000000&code=STUDENT20"),
            platform: .ios, expiresAt: WireJSON.parseDate("2026-12-31T23:59:59Z"), state: .available)))
    }

    func testOtherPlatformCodeShowsAHint() throws {
        let row = ChatPresentation.row(for: try Fixtures.decode(Message.self, "message-code-card-other-platform.json"), context: context())
        guard case .code(let code)? = row.card else { return XCTFail("Expected a code card") }
        XCTAssertEqual(code.state, .otherPlatform)
        XCTAssertNil(code.redeemURL)
        XCTAssertEqual(CodeCardView.hintKey(for: code.platform), "card.redeemOnIPhone")
        XCTAssertEqual(CodeCardView.hintKey(for: .android), "card.redeemOnAndroid")
        XCTAssertEqual(CodeCardView.hintKey(for: .web), "card.redeemOnWeb")
        XCTAssertNil(CodeCardView.hintKey(for: .any))
        let android = try fixture("message-code-card-other-platform.json", card: ["platform": "android"])
        guard case .code(let other)? = ChatPresentation.row(for: android, context: context()).card else { return XCTFail() }
        XCTAssertEqual(other.platform, .android)
        let future = try fixture("message-code-card-other-platform.json", card: ["platform": "watch"])
        guard case .code(let unknown)? = ChatPresentation.row(for: future, context: context()).card else { return XCTFail() }
        XCTAssertEqual(unknown.platform, .any, "Unknown platforms decode as any")
    }

    func testExpiredCodeHasNoActions() throws {
        let message = try Fixtures.decode(Message.self, "message-code-card.json")
        let after = WireJSON.parseDate("2027-01-01T00:00:00Z")!
        guard case .code(let code)? = ChatPresentation.row(for: message, context: context(now: after)).card else {
            return XCTFail("Expected a code card")
        }
        XCTAssertEqual(code.state, .expired)
        XCTAssertNil(code.redeemURL)
        // Expiry wins over the platform lock.
        let elsewhere = try fixture("message-code-card-other-platform.json", card: ["expiresAt": "2026-10-01T00:00:00Z"])
        guard case .code(let other)? = ChatPresentation.row(for: elsewhere, context: context()).card else { return XCTFail() }
        XCTAssertEqual(other.state, .expired)
    }

    func testAvailableCodeWithoutURLHasNoRedeem() throws {
        let message = try fixture("message-code-card.json", card: ["url": NSNull()])
        guard case .code(let code)? = ChatPresentation.row(for: message, context: context()).card else { return XCTFail() }
        XCTAssertEqual(code.state, .available)
        XCTAssertNil(code.redeemURL)
    }

    func testCodeCardWithoutACodeRendersAsText() throws {
        let message = try fixture("message-code-card.json", card: ["code": NSNull()])
        let row = ChatPresentation.row(for: message, context: context())
        XCTAssertNil(row.card)
        XCTAssertEqual(row.text, "Here's 20% off yearly with your student discount.")
    }

    func testNextExpiry() throws {
        let messages = [try Fixtures.decode(Message.self, "message-code-card.json"),
                        try Fixtures.decode(Message.self, "message-code-card-other-platform.json"),
                        try Fixtures.decode(Message.self, "message-app-card.json")]
        XCTAssertEqual(ChatPresentation.nextExpiry(in: messages, after: beforeExpiry), WireJSON.parseDate("2026-12-31T23:59:59Z"))
        XCTAssertNil(ChatPresentation.nextExpiry(in: messages, after: WireJSON.parseDate("2027-01-01T00:00:00Z")!))
    }

    // MARK: Accessibility and strings

    func testCodeIsSpokenCharacterByCharacter() {
        XCTAssertEqual(CodeCardView.spokenCode("STUDENT20"), "S T U D E N T 2 0")
        XCTAssertEqual(CodeCardView.spokenCode("ab-1"), "a b - 1")
    }

    func testNewCardStringsAreTranslatedInEveryLanguage() {
        let keys = ["card.getApp", "card.installed", "card.codeTag", "card.copy", "card.copied", "card.redeem",
                    "card.redeemOnIPhone", "card.redeemOnAndroid", "card.redeemOnWeb", "card.expired", "card.expiresOn"]
        for language in Localization.supported {
            let bundle = Localization.bundle(for: language)
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "\u{0}missing", table: "Localizable")
                XCTAssertNotEqual(value, "\u{0}missing", "\(key) is missing in \(language)")
                XCTAssertFalse(value.isEmpty, "\(key) is empty in \(language)")
            }
            XCTAssertTrue(bundle.localizedString(forKey: "card.expiresOn", value: nil, table: "Localizable").contains("%@"),
                          "card.expiresOn needs its placeholder in \(language)")
        }
        XCTAssertEqual(Strings(language: "es").format("card.expiresOn", "31 dic 2026"), "Caduca el 31 dic 2026")
    }
}

/// Buttons on the new cards: events and `POST /v1/sdk/actions/:messageId` receipts.
@MainActor
final class PromoCardActionTests: XCTestCase {
    private var harness: EngineHarness!

    override func setUp() async throws {
        harness = EngineHarness()
        harness.stubRegister()
        try await harness.engine.ensureRegistered()
    }

    override func tearDown() async throws {
        harness.cleanUp()
    }

    private func row(_ name: String, card changes: [String: Any] = [:]) throws -> ChatRow {
        var json = try JSONSerialization.jsonObject(with: Fixtures.data(name)) as! [String: Any]
        var card = json["card"] as! [String: Any]
        for (key, value) in changes { card[key] = value }
        json["card"] = card
        let message = try WireJSON.decoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json))
        harness.engine.chat.handle(.message(message))
        return try XCTUnwrap(harness.engine.chat.rows.first { $0.messageId == message.id })
    }

    private func receipts(_ messageId: String) -> [String] {
        harness.transport.requests("POST", "/v1/sdk/actions/\(messageId)").compactMap { $0.json?["action"] as? String }
    }

    func testAppPromoTapEmitsAndSendsTheOpenReceipt() async throws {
        harness.transport.on("POST", "/v1/sdk/actions/msg_7", status: 204)
        let row = try row("message-app-card.json")
        harness.engine.chat.openCard(row)
        XCTAssertEqual(harness.events, [.appPromoOpened])
        await waitUntil { !receipts("msg_7").isEmpty }
        XCTAssertEqual(receipts("msg_7"), ["open"])
    }

    func testInstalledAppPromoDoesNothing() async throws {
        let row = try row("message-app-card.json", card: ["installed": true])
        harness.engine.chat.openCard(row)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.events, [])
        XCTAssertEqual(receipts("msg_7"), [])
    }

    func testCopyEmitsAndSendsTheCopyReceipt() async throws {
        harness.transport.on("POST", "/v1/sdk/actions/msg_8", status: 204)
        let row = try row("message-code-card.json")
        XCTAssertTrue(harness.engine.chat.copyCode(row))
        XCTAssertEqual(harness.events, [.codeCopied])
        await waitUntil { !receipts("msg_8").isEmpty }
        XCTAssertEqual(receipts("msg_8"), ["copy"])
    }

    func testRedeemEmitsAndSendsTheOpenReceipt() async throws {
        harness.transport.on("POST", "/v1/sdk/actions/msg_8", status: 204)
        let row = try row("message-code-card.json")
        harness.engine.chat.openCard(row)
        XCTAssertEqual(harness.events, [.codeOpened])
        await waitUntil { !receipts("msg_8").isEmpty }
        XCTAssertEqual(receipts("msg_8"), ["open"])
    }

    func testOtherPlatformCodeCopiesButCannotRedeem() async throws {
        harness.transport.on("POST", "/v1/sdk/actions/msg_9", status: 204)
        let row = try row("message-code-card-other-platform.json")
        harness.engine.chat.openCard(row)
        XCTAssertEqual(harness.events, [], "No Redeem on another platform")
        XCTAssertTrue(harness.engine.chat.copyCode(row))
        XCTAssertEqual(harness.events, [.codeCopied])
        await waitUntil { !receipts("msg_9").isEmpty }
        XCTAssertEqual(receipts("msg_9"), ["copy"])
    }

    func testExpiredCodeDoesNothing() async throws {
        let row = try row("message-code-card.json", card: ["expiresAt": "2026-01-01T00:00:00Z"])
        guard case .code(let code)? = row.card else { return XCTFail("Expected a code card") }
        XCTAssertEqual(code.state, .expired)
        XCTAssertFalse(harness.engine.chat.copyCode(row))
        harness.engine.chat.openCard(row)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.events, [])
        XCTAssertEqual(receipts("msg_8"), [])
    }

    func testCodeExpiresWhileTheThreadIsOpen() async throws {
        let soon = WireJSON.formatDate(harness.clock.now.addingTimeInterval(0.2))
        _ = try row("message-code-card.json", card: ["expiresAt": soon])
        guard case .code(let code)? = harness.engine.chat.rows.first?.card else { return XCTFail("Expected a code card") }
        XCTAssertEqual(code.state, .available)
        harness.clock.advance(1)
        await waitUntil(timeout: 3) {
            if case .code(let code)? = self.harness.engine.chat.rows.first?.card { return code.state == .expired }
            return false
        }
    }
}
