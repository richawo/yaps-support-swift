import SwiftUI
import XCTest
@testable import YapsSupport

/// The translation rule, read ticks and the appearance precedence.
final class TranslationTests: XCTestCase {
    func testShowsTranslationInTheCustomerLanguage() throws {
        let message = try Fixtures.decode(Message.self, "message-agent-translated.json")
        XCTAssertEqual(ChatPresentation.displayText(for: message, customerLanguage: "es"), "¡Sí! Ajustes → Apariencia → Oscuro.")
        XCTAssertEqual(ChatPresentation.displayText(for: message, customerLanguage: "es-MX"), "¡Sí! Ajustes → Apariencia → Oscuro.")
        XCTAssertEqual(ChatPresentation.displayText(for: message, customerLanguage: "ES"), "¡Sí! Ajustes → Apariencia → Oscuro.")
    }

    func testShowsOriginalOtherwise() throws {
        let message = try Fixtures.decode(Message.self, "message-agent-translated.json")
        XCTAssertEqual(ChatPresentation.displayText(for: message, customerLanguage: "en"), "Yes! Settings → Appearance → Dark.")
        XCTAssertEqual(ChatPresentation.displayText(for: message, customerLanguage: "fr"), "Yes! Settings → Appearance → Dark.")
        let plain = try Fixtures.decode(Message.self, "message-text.json")
        XCTAssertEqual(ChatPresentation.displayText(for: plain, customerLanguage: "es"), "is there a dark mode?")
    }

    func testChineseScriptsDoNotMatchEachOther() {
        XCTAssertFalse(ChatPresentation.languagesMatch("zh-Hans", "zh-Hant"))
        XCTAssertTrue(ChatPresentation.languagesMatch("zh-Hant", "zh-hant"))
        XCTAssertTrue(ChatPresentation.languagesMatch("pt_BR", "pt-BR"))
    }

    @MainActor
    func testEngineUsesServerCustomerLanguage() async throws {
        let harness = EngineHarness()
        defer { harness.cleanUp() }
        harness.settings.languageOverride = "en"
        XCTAssertEqual(harness.engine.customerLanguage, "en")
        harness.stubRegister()
        try await harness.engine.ensureRegistered()
        XCTAssertEqual(harness.engine.customerLanguage, "es", "config.translation.customerLanguage wins")
    }

    func testOutgoingReadTicksFollowAgentReadSeq() throws {
        let messages = [message(id: "m1", seq: 1, author: .customer, clientId: "c1"),
                        message(id: "m2", seq: 2, author: .customer, clientId: "c2"),
                        message(id: "m3", seq: 3, author: .agent)]
        let context = ChatPresentation.Context(customerLanguage: "en", agentReadSeq: 1, isPaywallAvailable: { _ in false },
                                               fileURL: { URL(fileURLWithPath: $0) })
        let rows = ChatPresentation.rows(messages: messages, outbox: [], context: context)
        XCTAssertEqual(rows.map(\.delivery), [.read, .sent, .none])
        XCTAssertEqual(rows.map(\.id), ["c:c1", "c:c2", "m:m3"], "Rows keep the client ID so a confirmed send doesn't re-insert")
    }

    func testTeamDisplaySettingsHideNamesAndPhotos() throws {
        let message = try Fixtures.decode(Message.self, "message-agent-translated.json")
        let context = ChatPresentation.Context(customerLanguage: "en", agentReadSeq: 0, showNames: false, showPhotos: false,
                                               isPaywallAvailable: { _ in false }, fileURL: { URL(fileURLWithPath: $0) })
        let row = ChatPresentation.row(for: message, context: context)
        XCTAssertNil(row.authorName)
        XCTAssertNil(row.avatarURL)
    }
}

final class AppearancePrecedenceTests: XCTestCase {
    private func resolve(remote: RemoteAppearance?, local: SupportAppearance = SupportAppearance(), language: String = "en") -> ResolvedAppearance {
        AppearanceResolver.resolve(remote: remote, local: local, language: language, strings: { "default:\($0)" })
    }

    func testDefaultsWhenNothingIsSet() {
        let resolved = resolve(remote: nil)
        XCTAssertEqual(resolved.accent, .standard(.accent))
        XCTAssertEqual(resolved.background, .standard(.background))
        XCTAssertEqual(resolved.title, "default:chat.title")
        XCTAssertEqual(resolved.welcomeTitle, "default:welcome.title")
        XCTAssertEqual(resolved.fontDesign, .default)
        XCTAssertEqual(resolved.cornerStyle, .round)
        XCTAssertEqual(resolved.colorScheme, .system)
        XCTAssertTrue(resolved.showsCloseButton)
        XCTAssertFalse(resolved.fadesOlderMessages)
    }

    func testLocalBeatsDefault() {
        var local = SupportAppearance()
        local.accentColor = .orange
        local.title = "Help"
        local.fontDesign = .serif
        local.cornerStyle = .square
        local.showsCloseButton = false
        local.colorScheme = .dark
        let resolved = resolve(remote: nil, local: local)
        XCTAssertEqual(resolved.accent, .local(.orange))
        XCTAssertEqual(resolved.onAccent, .standard(.onAccent))
        XCTAssertEqual(resolved.title, "Help")
        XCTAssertEqual(resolved.fontDesign, .serif)
        XCTAssertEqual(resolved.cornerStyle, .square)
        XCTAssertFalse(resolved.showsCloseButton)
        XCTAssertEqual(resolved.preferredColorScheme, .dark)
    }

    func testRemoteBeatsLocal() throws {
        let remote = try Fixtures.decode(RemoteAppearance.self, "appearance.json")
        var local = SupportAppearance()
        local.accentColor = .green
        local.title = "Help"
        local.fontDesign = .serif
        local.showsCloseButton = false
        local.welcomeText = "Local text"
        let resolved = resolve(remote: remote, local: local)
        XCTAssertEqual(resolved.accent, .remote(ColorPair(light: "#FF7A45", dark: "#FF8A5B")))
        XCTAssertEqual(resolved.title, "Clucky support")
        XCTAssertEqual(resolved.welcomeText, "We usually reply within a few hours.")
        XCTAssertEqual(resolved.fontDesign, .rounded)
        XCTAssertTrue(resolved.showsCloseButton)
    }

    func testMissingRemoteFieldsFallBackToLocalThenDefault() throws {
        var remote = try Fixtures.decode(RemoteAppearance.self, "appearance.json")
        remote.colors?.accent = nil
        remote.welcomeTitle = nil
        remote.fontStyle = nil
        remote.showCloseButton = nil
        var local = SupportAppearance()
        local.accentColor = .pink
        local.fontDesign = .monospaced
        let resolved = resolve(remote: remote, local: local)
        XCTAssertEqual(resolved.accent, .local(.pink))
        XCTAssertEqual(resolved.fontDesign, .monospaced)
        XCTAssertEqual(resolved.welcomeTitle, "default:welcome.title")
        XCTAssertTrue(resolved.showsCloseButton)
        XCTAssertEqual(resolved.background, .remote(ColorPair(light: "#FFFFFF", dark: "#000000")))
    }

    func testRemoteTextFollowsLanguageThenEnglish() throws {
        let remote = try Fixtures.decode(RemoteAppearance.self, "appearance.json")
        XCTAssertEqual(resolve(remote: remote, language: "es").title, "Soporte de Clucky")
        XCTAssertEqual(resolve(remote: remote, language: "es-MX").title, "Soporte de Clucky")
        XCTAssertEqual(resolve(remote: remote, language: "fr").title, "Clucky support")
        XCTAssertEqual(resolve(remote: remote, language: "fr").welcomeTitle, "How can we help?")
    }

    func testInvalidRemoteColourIsIgnored() {
        var remote = RemoteAppearance()
        remote.colors = .init(accent: ColorPair(light: "orange", dark: "#123"))
        var local = SupportAppearance()
        local.accentColor = .red
        XCTAssertEqual(resolve(remote: remote, local: local).accent, .local(.red))
    }

    func testWelcomeIcon() {
        guard case .symbol(ResolvedAppearance.defaultWelcomeSymbol) = resolve(remote: nil).welcomeIcon else { return XCTFail() }
        var local = SupportAppearance()
        local.welcomeIcon = .hidden
        guard case .hidden = resolve(remote: nil, local: local).welcomeIcon else { return XCTFail() }
        var remote = RemoteAppearance()
        remote.welcomeIconUrl = "https://support.test/icon.png"
        guard case .url(let url) = resolve(remote: remote, local: local).welcomeIcon else { return XCTFail() }
        XCTAssertEqual(url.absoluteString, "https://support.test/icon.png")
    }

    func testHexParsing() {
        XCTAssertNotNil(UIColor(hex: "#FF7A45"))
        XCTAssertNotNil(UIColor(hex: "FF7A4580"))
        XCTAssertNotNil(UIColor(hex: "#abc"))
        XCTAssertNil(UIColor(hex: "#12"))
        XCTAssertNil(UIColor(hex: "zzzzzz"))
    }

    @MainActor
    func testRemoteAppearanceIsCachedWithETagAndCanBeDisabled() async throws {
        let harness = EngineHarness()
        defer { harness.cleanUp() }
        harness.transport.on("GET", "/v1/sdk/appearance", data: try Fixtures.data("appearance.json"), headers: ["ETag": #"W/"a1""#])
        harness.transport.on("GET", "/v1/sdk/appearance", status: 304)
        var local = SupportAppearance()
        local.title = "Help"
        harness.settings.appearance = local

        XCTAssertEqual(harness.engine.resolvedAppearance().title, "Help")
        await harness.engine.appearanceStore.refresh()
        XCTAssertEqual(harness.engine.resolvedAppearance().title, "Clucky support")
        let first = try XCTUnwrap(harness.transport.requests("GET", "/v1/sdk/appearance").first)
        XCTAssertEqual(first.header("X-Support-App"), "app_123")
        XCTAssertNil(first.header("Authorization"), "Appearance is public")
        XCTAssertNil(first.header("If-None-Match"))

        await harness.engine.appearanceStore.refresh()
        let second = try XCTUnwrap(harness.transport.requests("GET", "/v1/sdk/appearance").last)
        XCTAssertEqual(second.header("If-None-Match"), #"W/"a1""#)
        XCTAssertEqual(harness.engine.resolvedAppearance().title, "Clucky support", "304 keeps the cached appearance")

        // The cache survives a relaunch.
        let relaunched = harness.makeEngine()
        relaunched.appearanceStore.load()
        XCTAssertEqual(relaunched.resolvedAppearance().title, "Clucky support")

        harness.settings.usesRemoteAppearance = false
        XCTAssertEqual(harness.engine.resolvedAppearance().title, "Help")
    }
}

final class PushRecognitionTests: XCTestCase {
    func testAPNsFixtureIsRecognised() throws {
        let payload = try XCTUnwrap(SupportPushPayload.parse(try Fixtures.json("push-apns.json")))
        XCTAssertEqual(payload, SupportPushPayload(conversationId: "cnv_1", messageId: "msg_9", badge: 1))
    }

    func testFCMDataFixtureIsRecognised() throws {
        let payload = try XCTUnwrap(SupportPushPayload.parse(try Fixtures.json("push-fcm-data.json")))
        XCTAssertEqual(payload, SupportPushPayload(conversationId: "cnv_1", messageId: "msg_9", badge: 1))
    }

    func testForeignPayloadsAreNotRecognised() {
        let foreign: [[AnyHashable: Any]] = [
            ["aps": ["alert": ["title": "Sale", "body": "50% off"], "badge": 3]],
            ["aps": ["content-available": 1], "custom": ["support": "1"]],
            ["support": "0", "conversationId": "cnv_1"],
            ["support": [String: Any]()],
            ["support": ["conversationId": ""]],
            ["support": "1"],
            [:],
        ]
        for payload in foreign {
            XCTAssertNil(SupportPushPayload.parse(payload), "\(payload)")
        }
    }

    func testPresentationOptions() throws {
        let payload = SupportPushPayload.parse(try Fixtures.json("push-apns.json"))
        XCTAssertNil(SupportPushPayload.presentationOptions(for: nil, chatOpen: false, currentConversationId: nil))
        XCTAssertEqual(SupportPushPayload.presentationOptions(for: payload, chatOpen: true, currentConversationId: "cnv_1"), [])
        XCTAssertEqual(SupportPushPayload.presentationOptions(for: payload, chatOpen: true, currentConversationId: nil), [])
        XCTAssertEqual(SupportPushPayload.presentationOptions(for: payload, chatOpen: false, currentConversationId: "cnv_1"),
                       [.banner, .list, .sound, .badge])
        XCTAssertEqual(SupportPushPayload.presentationOptions(for: payload, chatOpen: true, currentConversationId: "cnv_other"),
                       [.banner, .list, .sound, .badge])
    }

    @MainActor
    func testFacadeReturnsFalseAndNilForForeignPayloads() {
        let foreign: [AnyHashable: Any] = ["aps": ["alert": "Hello"]]
        XCTAssertFalse(YapsSupport.shared.handlePushNotification(userInfo: foreign, openChat: false))
        XCTAssertNil(YapsSupport.shared.notificationPresentationOptions(userInfo: foreign))
    }

    @MainActor
    func testPushRefreshesUnread() async throws {
        let harness = EngineHarness()
        defer { harness.cleanUp() }
        harness.stubRegister()
        harness.transport.on("GET", "/v1/sdk/unread", json: ["count": 2, "conversationId": "cnv_1"])
        try await harness.engine.ensureRegistered()
        let payload = try XCTUnwrap(SupportPushPayload.parse(try Fixtures.json("push-apns.json")))
        var opened = false
        harness.engine.onOpenRequested = { opened = true }
        harness.engine.handlePush(payload, openChat: false)
        XCTAssertEqual(harness.engine.unreadCount, 1, "The push badge is applied immediately")
        await waitUntil { harness.engine.unreadCount == 2 }
        XCTAssertFalse(opened)
        harness.engine.handlePush(payload, openChat: true)
        XCTAssertTrue(opened)
    }

    func testPushTokenHexAndEnvironment() {
        XCTAssertEqual(Data([0x0A, 0xFF, 0x10]).hexString, "0aff10")
        XCTAssertEqual(ProvisioningProfile.resolve(.sandbox), "sandbox")
        XCTAssertEqual(ProvisioningProfile.resolve(.production), "production")
        #if targetEnvironment(simulator)
        XCTAssertEqual(ProvisioningProfile.resolve(.automatic), "sandbox")
        #endif
    }

    func testProvisioningProfileParsing() {
        func profile(_ entitlements: String) -> Data {
            Data(("garbage\u{0}\u{1}<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Name</key><string>Dev</string>"
                + "<key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>\u{0}trailing").utf8)
        }
        XCTAssertEqual(ProvisioningProfile.apsEnvironment(fromProfile: profile("<key>aps-environment</key><string>development</string>")), "sandbox")
        XCTAssertEqual(ProvisioningProfile.apsEnvironment(fromProfile: profile("<key>aps-environment</key><string>production</string>")), "production")
        XCTAssertNil(ProvisioningProfile.apsEnvironment(fromProfile: profile("<key>get-task-allow</key><true/>")))
        XCTAssertNil(ProvisioningProfile.apsEnvironment(fromProfile: Data("not a profile".utf8)))
    }
}

final class LocalizationTests: XCTestCase {
    func testEverySupportedLanguageHasTranslatedStrings() {
        let english = Localization.string("welcome.title", language: "en")
        XCTAssertEqual(english, "How can we help?")
        for language in Localization.supported where language != "en" {
            let value = Localization.string("welcome.title", language: language)
            XCTAssertNotEqual(value, "welcome.title", language)
            XCTAssertNotEqual(value, english, "\(language) isn't translated")
        }
        XCTAssertEqual(Localization.supported.count, 22)
    }

    func testUploadFormatHasAPlaceholderInEveryLanguage() {
        for language in Localization.supported {
            let formatted = Strings(language: language).format("status.uploading", 42)
            XCTAssertTrue(formatted.contains("42"), "\(language): \(formatted)")
        }
    }

    func testLanguageMatching() {
        XCTAssertEqual(Localization.resolve(override: "es-MX"), "es")
        XCTAssertEqual(Localization.resolve(override: "pt-PT"), "pt-BR")
        XCTAssertEqual(Localization.resolve(override: "zh-TW"), "zh-Hant")
        XCTAssertEqual(Localization.resolve(override: "zh-Hant-HK"), "zh-Hant")
        XCTAssertEqual(Localization.resolve(override: "zh_CN"), "zh-Hans")
        XCTAssertEqual(Localization.resolve(override: "he-IL"), "he")
        XCTAssertEqual(Localization.resolve(override: "xx", preferred: ["de-AT"]), "de")
        XCTAssertEqual(Localization.resolve(override: nil, preferred: ["tlh"]), "en")
    }

    func testRightToLeft() {
        XCTAssertEqual(Strings(language: "ar").layoutDirection, .rightToLeft)
        XCTAssertEqual(Strings(language: "he").layoutDirection, .rightToLeft)
        XCTAssertEqual(Strings(language: "en").layoutDirection, .leftToRight)
    }

    func testPrivacyManifestIsBundled() throws {
        // The English .lproj lives inside the SDK's resource bundle, next to the manifest.
        let resources = try XCTUnwrap(Bundle(url: Localization.bundle(for: "en").bundleURL.deletingLastPathComponent()))
        let manifest = try XCTUnwrap(resources.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: manifest))
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertEqual(apis.first?["NSPrivacyAccessedAPIType"] as? String, "NSPrivacyAccessedAPICategoryUserDefaults")
        XCTAssertEqual(apis.first?["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
    }
}

final class UtilityTests: XCTestCase {
    func testULID() {
        let a = ULID.make(date: Date(timeIntervalSince1970: 1_793_318_400))
        let b = ULID.make(date: Date(timeIntervalSince1970: 1_793_318_401))
        XCTAssertEqual(a.count, 26)
        XCTAssertTrue(ULID.isValid(a))
        XCTAssertLessThan(a, b, "ULIDs sort by time")
        XCTAssertNotEqual(ULID.make(), ULID.make())
    }

    func testJWTUserIDWithoutVerification() {
        func token(_ claims: String) -> String {
            let payload = Data(claims.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
        }
        XCTAssertEqual(JWTClaims.userID(from: token(#"{"user_id":"u_42","exp":1}"#)), "u_42")
        XCTAssertEqual(JWTClaims.userID(from: token(#"{"user_id":42,"exp":1}"#)), "42")
        XCTAssertNil(JWTClaims.userID(from: token(#"{"sub":"u_42"}"#)))
        XCTAssertNil(JWTClaims.userID(from: "not-a-jwt"))
    }

    func testMetadataValidation() {
        var input = ["plan": "pro", "bad key": "x", "long": String(repeating: "a", count: 513)]
        for index in 0..<40 { input["k\(index)"] = "v" }
        let result = Validation.metadata(input)
        XCTAssertEqual(result.count, 30)
        XCTAssertNil(result["bad key"])
        XCTAssertNil(result["long"])
    }

    func testPaywallValidation() {
        var paywalls = [SupportPaywall(id: " yearly_offer ", title: " Yearly 40% off "),
                        SupportPaywall(id: "yearly_offer", title: "Duplicate"),
                        SupportPaywall(id: "bad id", title: "Nope"),
                        SupportPaywall(id: "no_title", title: "")]
        for index in 0..<25 { paywalls.append(SupportPaywall(id: "p\(index)", title: "Paywall \(index)")) }
        let result = Validation.paywalls(paywalls)
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(result.first, SupportPaywall(id: "yearly_offer", title: "Yearly 40% off"))
        XCTAssertFalse(result.contains { $0.id == "bad id" || $0.id == "no_title" })
    }

    func testIdentifierRule() {
        XCTAssertTrue(Validation.isIdentifier("paywall_declined"))
        XCTAssertTrue(Validation.isIdentifier("a.b-c_1"))
        XCTAssertFalse(Validation.isIdentifier(""))
        XCTAssertFalse(Validation.isIdentifier("has space"))
        XCTAssertFalse(Validation.isIdentifier(String(repeating: "a", count: 65)))
        XCTAssertFalse(Validation.isIdentifier("émoji"))
    }

    func testImageIsDownscaledToTheProtocolLimits() throws {
        let size = CGSize(width: 4032, height: 3024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            // Noise defeats JPEG compression so the byte limit is exercised.
            var generator = SystemRandomNumberGenerator()
            for y in stride(from: 0, to: Int(size.height), by: 12) {
                for x in stride(from: 0, to: Int(size.width), by: 12) {
                    UIColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                            blue: .random(in: 0...1, using: &generator), alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 12, height: 12))
                }
            }
        }
        let png = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(png.count, Validation.maxImageBytes)
        let prepared = try XCTUnwrap(ImageProcessor.prepareJPEG(from: png))
        XCTAssertLessThanOrEqual(max(prepared.width, prepared.height), 2048)
        XCTAssertLessThanOrEqual(prepared.data.count, Validation.maxImageBytes)
        XCTAssertEqual(prepared.data.prefix(2), Data([0xFF, 0xD8]), "Output is JPEG")
        XCTAssertEqual(Double(prepared.width) / Double(prepared.height), 4032.0 / 3024.0, accuracy: 0.01)
    }

    func testFileContentTypes() {
        XCTAssertEqual(FileAttachmentPolicy.contentType(for: URL(fileURLWithPath: "/a/report.PDF")), "application/pdf")
        XCTAssertEqual(FileAttachmentPolicy.contentType(for: URL(fileURLWithPath: "/a/crash.log")), "text/plain")
        XCTAssertEqual(FileAttachmentPolicy.contentType(for: URL(fileURLWithPath: "/a/logs.zip")), "application/zip")
        XCTAssertNil(FileAttachmentPolicy.contentType(for: URL(fileURLWithPath: "/a/movie.mov")))
    }
}
