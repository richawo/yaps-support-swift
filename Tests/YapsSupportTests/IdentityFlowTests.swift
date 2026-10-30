import XCTest
@testable import YapsSupport

/// Registration, unverified identity labels, device updates and session lifecycle. Everything here
/// runs without a JWT except the token-rejection test.
@MainActor
final class IdentityFlowTests: XCTestCase {
    private var harness: EngineHarness!
    private var engine: SupportEngine { harness.engine }

    override func setUp() async throws {
        harness = EngineHarness()
        harness.settings.languageOverride = "en"
        harness.stubRegister()
        harness.stubDeviceUpdate()
    }

    override func tearDown() async throws {
        harness.cleanUp()
    }

    func testRegisterSendsLabelsMetadataAndHeaders() async throws {
        engine.identify(userID: "u_42", name: "Ada", email: "ada@example.com")
        engine.setMetadata(["plan": "pro"])
        let token = try await engine.ensureRegistered()
        XCTAssertEqual(token, "dt_reg_1_secret")

        let register = try XCTUnwrap(harness.transport.requests("POST", "/v1/sdk/register").first)
        XCTAssertEqual(register.header("X-Support-App"), "app_123")
        XCTAssertEqual(register.header("X-Support-SDK"), "ios/\(YapsSupport.version)")
        XCTAssertNil(register.header("Authorization"))
        let body = try XCTUnwrap(register.json)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["identity"] as? [String: String], ["userId": "u_42", "name": "Ada", "email": "ada@example.com"])
        XCTAssertEqual(body["metadata"] as? [String: String], ["plan": "pro"])
        let device = try XCTUnwrap(body["device"] as? [String: Any])
        XCTAssertEqual(device["language"] as? String, "en")
        XCTAssertNotNil(device["osVersion"])
        XCTAssertNotNil(device["timeZone"])

        XCTAssertEqual(try harness.secureStore.read("app_123.deviceToken"), "dt_reg_1_secret", "Token goes to secure storage")
        XCTAssertEqual(engine.registrationId, "reg_1")
        XCTAssertEqual(engine.config?.appName, "Clucky")
    }

    func testConcurrentCallersShareOneRegistration() async throws {
        let engine = self.engine
        let first = Task { try await engine.ensureRegistered() }
        let second = Task { try await engine.ensureRegistered() }
        _ = try await (first.value, second.value)
        XCTAssertEqual(harness.transport.requests("POST", "/v1/sdk/register").count, 1)
    }

    func testTokenIsReusedAfterRelaunch() async throws {
        try await engine.ensureRegistered()
        let relaunched = harness.makeEngine()
        let token = try await relaunched.ensureRegistered()
        XCTAssertEqual(token, "dt_reg_1_secret")
        XCTAssertEqual(harness.transport.requests("POST", "/v1/sdk/register").count, 1)
    }

    func testDeviceUpdateSendsOnlyChangedFields() async throws {
        engine.identify(userID: "u_42", name: "Ada", email: nil)
        engine.setMetadata(["plan": "pro"])
        try await engine.ensureRegistered()
        XCTAssertNil(engine.pendingDeviceUpdate(), "Nothing changed since registration")

        engine.identify(userID: "u_42", name: "Ada Lovelace", email: "ada@example.com")
        await engine.syncDevice()
        let first = try XCTUnwrap(harness.transport.requests("PATCH", "/v1/sdk/device").last)
        XCTAssertEqual(first.header("Authorization"), "Bearer dt_reg_1_secret")
        XCTAssertEqual(first.json?["identity"] as? [String: String], ["userId": "u_42", "name": "Ada Lovelace", "email": "ada@example.com"])
        XCTAssertNil(first.json?["metadata"])
        XCTAssertNil(first.json?["identity"].flatMap { ($0 as? [String: Any])?["token"] })

        engine.setMetadata(["plan": "team", "seats": "5"])
        await engine.syncDevice()
        let second = try XCTUnwrap(harness.transport.requests("PATCH", "/v1/sdk/device").last)
        XCTAssertEqual(second.json?["metadata"] as? [String: String], ["plan": "team", "seats": "5"], "Metadata replaces the whole dictionary")
        XCTAssertNil(second.json?["identity"])
        XCTAssertNil(engine.pendingDeviceUpdate())
    }

    func testPushTokenAndBadgePreferenceAreSynced() async throws {
        try await engine.ensureRegistered()
        engine.setPushToken(Data([0xA1, 0xB2]), environment: .production)
        harness.settings.updatesAppBadge = false
        await engine.syncDevice()
        let patch = try XCTUnwrap(harness.transport.requests("PATCH", "/v1/sdk/device").last?.json)
        XCTAssertEqual(patch["push"] as? [String: String], ["token": "a1b2", "provider": "apns", "environment": "production"])
        XCTAssertEqual(patch["badgeEnabled"] as? Bool, false)
    }

    func testPaywallsAreReportedAfterAvailabilityCheck() async throws {
        try await engine.ensureRegistered()
        harness.settings.paywalls = [SupportPaywall(id: "yearly_offer", title: "Yearly 40% off",
                                                    products: [.init(id: "pro_yearly", price: "$29.99", period: "P1Y", trial: "P1W")]),
                                     SupportPaywall(id: "lifetime", title: "Lifetime")]
        harness.settings.paywallAvailability = { id in id != "lifetime" }
        engine.refreshPaywalls()
        await waitUntil { engine.availablePaywalls.count == 1 }
        await engine.syncDevice()
        let patch = try XCTUnwrap(harness.transport.requests("PATCH", "/v1/sdk/device").last?.json)
        let paywalls = try XCTUnwrap(patch["paywalls"] as? [[String: Any]])
        XCTAssertEqual(paywalls.map { $0["id"] as? String }, ["yearly_offer"])
        XCTAssertEqual((paywalls.first?["products"] as? [[String: String]])?.first,
                       ["id": "pro_yearly", "price": "$29.99", "period": "P1Y", "trial": "P1W"])
    }

    func testUnauthorizedRegistersAgainAndRetries() async throws {
        try await engine.ensureRegistered()
        harness.transport.on("GET", "/v1/sdk/unread", status: 401, json: ["error": ["code": "unauthorized", "message": "x"]])
        harness.transport.on("GET", "/v1/sdk/unread", json: ["count": 3])
        harness.transport.reset("POST", "/v1/sdk/register")
        harness.stubRegister(token: "dt_reg_2_secret")
        await engine.refreshUnread()
        XCTAssertEqual(engine.unreadCount, 3)
        XCTAssertEqual(engine.deviceToken, "dt_reg_2_secret")
        XCTAssertEqual(harness.transport.requests("POST", "/v1/sdk/register").count, 2)
        XCTAssertEqual(harness.transport.requests("GET", "/v1/sdk/unread").last?.header("Authorization"), "Bearer dt_reg_2_secret")
    }

    func testSwitchingUsersClearsTheLocalSession() async throws {
        engine.identify(userID: "u_1", name: "Ada", email: nil)
        try await engine.ensureRegistered()
        engine.chat.draft = "for Ada only"
        harness.transport.on("POST", "/v1/sdk/logout", status: 204)
        engine.identify(userID: "u_2", name: "Grace", email: nil)
        XCTAssertNil(engine.deviceToken)
        XCTAssertEqual(engine.chat.draft, "")
        XCTAssertEqual(engine.identity?.userId, "u_2")
        XCTAssertNil(engine.identity?.email)
        await waitUntil { !harness.transport.requests("POST", "/v1/sdk/logout").isEmpty }
        XCTAssertEqual(harness.transport.requests("POST", "/v1/sdk/logout").first?.header("Authorization"), "Bearer dt_reg_1_secret")
    }

    func testLogoutClearsLocalStateAndRevokesTheToken() async throws {
        harness.transport.on("POST", "/v1/sdk/logout", status: 204)
        engine.identify(userID: "u_1", name: nil, email: nil)
        engine.setMetadata(["plan": "pro"])
        engine.setPushToken(Data([1, 2]), environment: .sandbox)
        try await engine.ensureRegistered()
        engine.setUnread(2)
        engine.chat.draft = "draft"
        engine.logout()
        XCTAssertNil(engine.deviceToken)
        XCTAssertNil(try harness.secureStore.read("app_123.deviceToken"))
        XCTAssertNil(engine.identity)
        XCTAssertNil(engine.metadata)
        XCTAssertEqual(engine.unreadCount, 0)
        XCTAssertEqual(engine.chat.draft, "")
        XCTAssertNotNil(engine.push, "The device's APNs token is kept for the next session")
        await waitUntil { !harness.transport.requests("POST", "/v1/sdk/logout").isEmpty }

        try await engine.ensureRegistered()
        XCTAssertEqual(harness.transport.requests("POST", "/v1/sdk/register").count, 2)
        XCTAssertNil(harness.transport.requests("POST", "/v1/sdk/register").last?.json?["identity"])
    }

    func testDeleteDataSucceeds() async throws {
        harness.transport.on("DELETE", "/v1/sdk/device", status: 204)
        try await engine.ensureRegistered()
        try await engine.deleteData()
        XCTAssertEqual(harness.transport.requests("DELETE", "/v1/sdk/device").count, 1)
        XCTAssertNil(engine.deviceToken)
        XCTAssertEqual(harness.events.last, .dataDeleted)
    }

    func testDeleteDataFailureKeepsTheSession() async throws {
        harness.transport.on("DELETE", "/v1/sdk/device", status: 500, json: ["error": ["code": "server_error", "message": "x"]])
        try await engine.ensureRegistered()
        do {
            try await engine.deleteData()
            XCTFail("Expected an error")
        } catch let error as SupportError {
            XCTAssertEqual(error.code, "server_error")
        }
        XCTAssertEqual(engine.deviceToken, "dt_reg_1_secret")
        XCTAssertFalse(harness.events.contains(.dataDeleted))
    }

    func testUnknownAppDisablesTheSDK() async {
        harness.transport.reset("POST", "/v1/sdk/register")
        harness.transport.on("POST", "/v1/sdk/register", status: 404, json: ["error": ["code": "unknown_app", "message": "x"]])
        _ = try? await engine.ensureRegistered()
        XCTAssertTrue(engine.isDisabled)
        _ = try? await engine.ensureRegistered()
        XCTAssertEqual(harness.transport.requests("POST", "/v1/sdk/register").count, 1)
    }

    func testTrackSendsOnlyTrackedEvents() async throws {
        harness.transport.on("POST", "/v1/sdk/events", json: ["openChat": true])
        try await engine.ensureRegistered()
        var opened = false
        engine.onOpenRequested = { opened = true }
        engine.track("onboarding_completed", opensChat: false)
        engine.track("not valid!", opensChat: false)
        engine.track("paywall_declined", opensChat: true)
        await waitUntil { opened }
        let events = harness.transport.requests("POST", "/v1/sdk/events")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.json?["name"] as? String, "paywall_declined")
        XCTAssertEqual(events.first?.json?["opensChat"] as? Bool, true)
    }

    func testRejectedIdentityTokenEmitsEventAndContinuesUnverified() async throws {
        harness.transport.reset("POST", "/v1/sdk/register")
        harness.transport.on("POST", "/v1/sdk/register", status: 401, json: ["error": ["code": "identity_token_expired", "message": "x"]])
        harness.stubRegister()
        let payload = Data(#"{"user_id":"u_42","exp":1}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        engine.identify(token: "eyJhbGciOiJIUzI1NiJ9.\(payload).sig")
        XCTAssertEqual(engine.identity?.userId, "u_42", "The token's user_id is staged as the label")
        try await engine.ensureRegistered()
        let registers = harness.transport.requests("POST", "/v1/sdk/register")
        XCTAssertEqual(registers.count, 2)
        XCTAssertNotNil((registers[0].json?["identity"] as? [String: Any])?["token"])
        XCTAssertNil((registers[1].json?["identity"] as? [String: Any])?["token"])
        XCTAssertEqual(harness.events, [.identityRejected(SupportError(code: "identity_token_expired", status: 401, message: "x"))])
        XCTAssertNil(engine.identityToken)
    }

    func testIdentitySecretAndMalformedTokensAreIgnored() {
        engine.identify(token: "ids_live_secret")
        engine.identify(token: "not.a.jwt")
        engine.identify(token: String(repeating: "a", count: 4097))
        XCTAssertNil(engine.identityToken)
        XCTAssertNil(engine.identity)
    }

    func testOverlongLabelsAreLeftOut() {
        engine.identify(userID: "u_1", name: String(repeating: "n", count: 201), email: "a@example.com")
        XCTAssertNil(engine.identity?.name)
        XCTAssertEqual(engine.identity?.email, "a@example.com")
        engine.identify(userID: String(repeating: "u", count: 256), name: nil, email: nil)
        XCTAssertEqual(engine.identity?.userId, "u_1", "An invalid user ID is ignored")
    }
}
