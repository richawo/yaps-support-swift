import SwiftUI
import XCTest
@testable import YapsSupport

/// Bare `http(s)` URLs in message text become links; nothing else does.
final class TextLinkTests: XCTestCase {
    private func links(_ text: String) -> [String] {
        TextLinks.matches(in: text).map { String(text[$0.range]) }
    }

    func testTextLinkFixture() throws {
        let message = try Fixtures.decode(Message.self, "message-text-link.json")
        XCTAssertEqual(message.text, "The steps are at https://wakely.app/help/alarms, or email help@wakely.app.")
        let matches = TextLinks.matches(in: message.text)
        XCTAssertEqual(matches.map(\.url), [URL(string: "https://wakely.app/help/alarms")!],
                       "The URL is linked without its trailing comma and the email stays plain text")
    }

    func testTrailingPunctuationIsLeftOut() {
        XCTAssertEqual(links("See https://a.example/x."), ["https://a.example/x"])
        XCTAssertEqual(links("(https://a.example/x)"), ["https://a.example/x"])
        XCTAssertEqual(links("[https://a.example/x]!"), ["https://a.example/x"])
        XCTAssertEqual(links("Go: http://a.example/?q=1;"), ["http://a.example/?q=1"])
        XCTAssertEqual(links("Two https://a.example and https://b.example/y?z=1#top"),
                       ["https://a.example", "https://b.example/y?z=1#top"])
    }

    func testOnlyHTTPLinks() {
        XCTAssertEqual(links("mailto:help@wakely.app tel:+15551234 ftp://a.example javascript:alert(1)"), [])
        XCTAssertEqual(links("www.wakely.app"), [])
        XCTAssertEqual(links("<https://a.example/x>"), ["https://a.example/x"])
        XCTAssertEqual(links("\"https://a.example/x\""), ["https://a.example/x"])
    }

    func testMarkdownAndHTMLStayLiteral() {
        let text = "**bold** [x](https://a.example/y) <b>hi</b> _it_"
        let attributed = TextLinks.attributed(text, links: TextLinks.matches(in: text), color: .red)
        XCTAssertEqual(String(attributed.characters), text, "Every character is shown as typed")
        let linked = attributed.runs.compactMap { run in run.link.map { ($0, String(attributed[run.range].characters)) } }
        XCTAssertEqual(linked.map(\.0), [URL(string: "https://a.example/y")!])
        XCTAssertEqual(linked.map(\.1), ["https://a.example/y"])
    }

    func testLinksAreUnderlinedInTheInk() {
        let text = "Read https://a.example/guide now"
        let attributed = TextLinks.attributed(text, links: TextLinks.matches(in: text), color: .blue)
        typealias SwiftUIKeys = AttributeScopes.SwiftUIAttributes
        let link = attributed.runs.first { $0.link != nil }
        XCTAssertEqual(link?[SwiftUIKeys.UnderlineStyleAttribute.self], .single)
        XCTAssertEqual(link?[SwiftUIKeys.ForegroundColorAttribute.self], .blue)
        let plain = attributed.runs.filter { $0.link == nil }
        XCTAssertEqual(plain.count, 2)
        XCTAssertTrue(plain.allSatisfy { $0[SwiftUIKeys.UnderlineStyleAttribute.self] == nil })
    }
}

/// Link cards (§5): decoding, which state each card renders in, and refused schemes.
final class LinkCardPresentationTests: XCTestCase {
    private func context(screens: Set<String> = []) -> ChatPresentation.Context {
        ChatPresentation.Context(customerLanguage: "en", agentReadSeq: 0, isPaywallAvailable: { _ in false },
                                 isScreenAvailable: { screens.contains($0) }, fileURL: { URL(fileURLWithPath: "/tmp/\($0)") })
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

    private func link(_ message: Message, screens: Set<String> = []) -> ChatRow.LinkButton? {
        guard case .link(let link)? = ChatPresentation.row(for: message, context: context(screens: screens)).card else { return nil }
        return link
    }

    // MARK: Decoding

    func testURLLinkCardFixtureDecodes() throws {
        let message = try Fixtures.decode(Message.self, "message-link-card.json")
        let card = try XCTUnwrap(message.card)
        XCTAssertEqual(card.known, .link)
        XCTAssertEqual(card.buttonLabel, "Read the guide")
        XCTAssertEqual(card.linkId, "lnk_1")
        XCTAssertEqual(card.target, "url")
        XCTAssertEqual(card.url, "https://wakely.app/guide/silent-alarms")
        XCTAssertNil(card.screenId)
        XCTAssertEqual(card.available, true)
        XCTAssertNil(card.openedAt)
    }

    func testScreenAndSettingsLinkCardFixturesDecode() throws {
        let screen = try XCTUnwrap(try Fixtures.decode(Message.self, "message-link-card-screen.json").card)
        XCTAssertEqual(screen.known, .link)
        XCTAssertEqual(screen.target, "screen")
        XCTAssertEqual(screen.screenId, "edit_profile")
        XCTAssertEqual(screen.linkId, "lnk_3")
        XCTAssertNil(screen.url)
        let settings = try XCTUnwrap(try Fixtures.decode(Message.self, "message-link-card-settings.json").card)
        XCTAssertEqual(settings.known, .link)
        XCTAssertEqual(settings.target, "app_settings")
        XCTAssertEqual(settings.buttonLabel, "Open settings")
        XCTAssertNil(settings.screenId)
    }

    // MARK: States

    func testURLLinkCard() throws {
        let row = ChatPresentation.row(for: try Fixtures.decode(Message.self, "message-link-card.json"), context: context())
        XCTAssertEqual(row.card, .link(ChatRow.LinkButton(label: "Read the guide",
                                                          target: .url(URL(string: "https://wakely.app/guide/silent-alarms")!),
                                                          available: true, linkId: "lnk_1")))
        XCTAssertEqual(row.text, "Our guide walks through why an alarm might stay silent.")
    }

    func testSettingsLinkCard() throws {
        let message = try Fixtures.decode(Message.self, "message-link-card-settings.json")
        XCTAssertEqual(link(message), ChatRow.LinkButton(label: "Open settings", target: .appSettings, available: true, linkId: "lnk_2"))
        XCTAssertEqual(link(try fixture("message-link-card-settings.json", card: ["available": false]))?.available, false)
    }

    func testScreenLinkCardNeedsTheScreenHere() throws {
        let message = try Fixtures.decode(Message.self, "message-link-card-screen.json")
        XCTAssertEqual(link(message, screens: ["edit_profile"]),
                       ChatRow.LinkButton(label: "Edit profile", target: .screen(id: "edit_profile"), available: true, linkId: "lnk_3"))
        XCTAssertEqual(link(message, screens: [])?.available, false, "Not registered here (or no onScreen)")
        XCTAssertEqual(link(message, screens: ["other"])?.available, false)
        let serverOff = try fixture("message-link-card-screen.json", card: ["available": false])
        XCTAssertEqual(link(serverOff, screens: ["edit_profile"])?.available, false, "The server's available wins")
    }

    func testUnavailableURLLinkStaysACard() throws {
        let message = try fixture("message-link-card.json", card: ["available": false])
        XCTAssertEqual(link(message)?.available, false)
    }

    func testAllowedSchemes() throws {
        for url in ["https://wakely.app", "mailto:help@wakely.app", "tel:+15551234567", "sms:+15551234567", "HTTPS://WAKELY.APP"] {
            XCTAssertNotNil(link(try fixture("message-link-card.json", card: ["url": url])), url)
        }
    }

    func testOtherSchemesRenderAsText() throws {
        for url in ["http://wakely.app", "javascript:alert(1)", "file:///etc/passwd", "wakely://settings", "data:text/html,hi", "not a url"] {
            let row = ChatPresentation.row(for: try fixture("message-link-card.json", card: ["url": url]), context: context())
            XCTAssertNil(row.card, url)
            XCTAssertEqual(row.text, "Our guide walks through why an alarm might stay silent.", url)
        }
        XCTAssertFalse(ChatPresentation.isAllowedLink(URL(string: "javascript:alert(1)")!))
    }

    func testMalformedLinkCardsRenderAsText() throws {
        let broken: [[String: Any]] = [["target": "calendar"], ["target": NSNull()], ["buttonLabel": NSNull()],
                                       ["buttonLabel": "  "], ["url": NSNull()]]
        for changes in broken {
            XCTAssertNil(ChatPresentation.row(for: try fixture("message-link-card.json", card: changes), context: context()).card,
                         "\(changes)")
        }
        let noScreen = try fixture("message-link-card-screen.json", card: ["screenId": NSNull()])
        XCTAssertNil(ChatPresentation.row(for: noScreen, context: context(screens: ["edit_profile"])).card)
    }

    func testLinkCardWithoutTextFallsBackToItsLabel() throws {
        var message = try fixture("message-link-card.json", card: ["url": "javascript:alert(1)"])
        message.text = ""
        XCTAssertEqual(ChatPresentation.row(for: message, context: context()).text, "Read the guide")
    }

    // MARK: Destination tag

    func testDestinationTag() {
        func tag(_ string: String) -> String? { LinkCardView.destination(for: .url(URL(string: string)!))?.text }
        XCTAssertEqual(tag("https://www.Wakely.app/guide"), "wakely.app")
        XCTAssertEqual(tag("https://help.wakely.app"), "help.wakely.app")
        XCTAssertEqual(tag("mailto:help@wakely.app?subject=Alarms"), "help@wakely.app")
        XCTAssertEqual(tag("tel:+15551234567"), "+15551234567")
        XCTAssertEqual(LinkCardView.destination(for: .url(URL(string: "sms:+15551234567")!))?.icon, "message.fill")
        XCTAssertNil(LinkCardView.destination(for: .appSettings))
        XCTAssertNil(LinkCardView.destination(for: .screen(id: "edit_profile")))
        XCTAssertEqual(LinkCardView.symbol(for: .screen(id: "edit_profile")), "chevron.right")
    }
}

/// Link card buttons: what opens, the `linkOpened` event and the open receipt.
@MainActor
final class LinkCardActionTests: XCTestCase {
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

    func testURLLinkEmitsAndSendsTheOpenReceipt() async throws {
        harness.transport.on("POST", "/v1/sdk/actions/msg_10", status: 204)
        harness.engine.chat.openCard(try row("message-link-card.json"))
        XCTAssertEqual(harness.events, [.linkOpened(messageId: "msg_10", linkId: "lnk_1")])
        await waitUntil { !receipts("msg_10").isEmpty }
        XCTAssertEqual(receipts("msg_10"), ["open"])
    }

    func testSettingsLinkEmitsAndSendsTheOpenReceipt() async throws {
        harness.transport.on("POST", "/v1/sdk/actions/msg_12", status: 204)
        harness.engine.chat.openCard(try row("message-link-card-settings.json"))
        XCTAssertEqual(harness.events, [.linkOpened(messageId: "msg_12", linkId: "lnk_2")])
        await waitUntil { !receipts("msg_12").isEmpty }
        XCTAssertEqual(receipts("msg_12"), ["open"])
    }

    func testScreenLinkClosesTheChatThenCallsOnScreen() async throws {
        harness.transport.on("POST", "/v1/sdk/actions/msg_11", status: 204)
        var steps: [String] = []
        harness.settings.onScreen = { steps.append("onScreen \($0)") }
        harness.settings.screens = [SupportScreen(id: "edit_profile", title: "Edit profile")]
        harness.engine.refreshScreens()
        harness.engine.onDismissThen = { completion in
            steps.append("close")
            completion()
        }
        let row = try row("message-link-card-screen.json")
        guard case .link(let link)? = row.card else { return XCTFail("Expected a link card") }
        XCTAssertTrue(link.available)
        harness.engine.chat.openCard(row)
        XCTAssertEqual(steps, ["close", "onScreen edit_profile"])
        XCTAssertEqual(harness.events, [.linkOpened(messageId: "msg_11", linkId: "lnk_3")])
        await waitUntil { !receipts("msg_11").isEmpty }
        XCTAssertEqual(receipts("msg_11"), ["open"])
    }

    func testScreenLinkUpdatesWhenScreensOrTheHandlerChange() throws {
        _ = try row("message-link-card-screen.json")
        func available() -> Bool? {
            guard case .link(let link)? = harness.engine.chat.rows.first?.card else { return nil }
            return link.available
        }
        XCTAssertEqual(available(), false)
        harness.settings.screens = [SupportScreen(id: "edit_profile", title: "Edit profile")]
        harness.engine.refreshScreens()
        XCTAssertEqual(available(), false, "No onScreen handler yet")
        harness.settings.onScreen = { _ in }
        harness.engine.chat.screensChanged()
        XCTAssertEqual(available(), true)
        harness.settings.screens = []
        harness.engine.refreshScreens()
        XCTAssertEqual(available(), false)
    }

    func testUnavailableLinksDoNothing() async throws {
        var opened: [String] = []
        harness.settings.onScreen = { opened.append($0) }
        harness.engine.chat.openCard(try row("message-link-card-screen.json"))
        harness.engine.chat.openCard(try row("message-link-card.json", card: ["available": false]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(opened, [], "edit_profile isn't registered")
        XCTAssertEqual(harness.events, [])
        XCTAssertEqual(receipts("msg_10") + receipts("msg_11"), [])
    }

    func testRefusedSchemeIsNeverOpened() async throws {
        // Defence in depth: a row that somehow carries another scheme still does nothing.
        var forged = try row("message-link-card.json")
        forged.card = .link(ChatRow.LinkButton(label: "Go", target: .url(URL(string: "javascript:alert(1)")!), available: true))
        harness.engine.chat.openCard(forged)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.events, [])
        XCTAssertEqual(receipts("msg_10"), [])
    }
}
