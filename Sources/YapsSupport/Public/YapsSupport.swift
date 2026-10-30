import SwiftUI
import UIKit
import UserNotifications

/// In-app support chat by Support Yaps.
///
/// ```swift
/// YapsSupport.configure(appID: "app_123")
/// YapsSupport.shared.identify(userID: user.id, name: user.name, email: user.email)
/// Button("Contact support") { YapsSupport.openChat() }
/// ```
///
/// Everything is main-actor isolated except `version`, `logLevel` and `logHandler`.
@MainActor
public final class YapsSupport: ObservableObject {
    /// The shared instance.
    public static let shared = YapsSupport()

    /// The production service.
    public nonisolated static let defaultBaseURL = URL(string: "https://support.yaps.ai")!

    /// The SDK version, for example `"1.0.0"`.
    public nonisolated static var version: String { SDKInfo.version }

    /// Minimum level of SDK log lines. Defaults to `.info`. Readable and writable from any thread.
    public nonisolated static var logLevel: SupportLogLevel {
        get { Log.level }
        set { Log.level = newValue }
    }

    /// Receives SDK log lines instead of the console. Lines never contain message text, identity
    /// or metadata values, or tokens.
    public nonisolated static var logHandler: (@Sendable (SupportLogLevel, String) -> Void)? {
        get { Log.handler }
        set { Log.handler = newValue }
    }

    // MARK: Observable state

    /// Unread replies in the current conversation. Updated from push, foreground checks and the
    /// open chat.
    @Published public private(set) var unreadCount: Int = 0

    /// Whether chat content is on screen (the SDK sheet or a ``SupportChatView`` you placed).
    @Published public private(set) var isChatOpen: Bool = false

    /// Paywalls that offer cards may open, after `paywallAvailability` filtering.
    @Published public private(set) var availablePaywalls: [SupportPaywall] = []

    // MARK: Settings

    /// Whether the SDK sets the app icon badge to `unreadCount` and clears delivered Support
    /// notifications at zero. Defaults to `true`. Set `false` if your app owns the badge.
    public var updatesAppBadge: Bool {
        get { settings.updatesAppBadge }
        set {
            guard newValue != settings.updatesAppBadge else { return }
            settings.updatesAppBadge = newValue
            engine?.badgePreferenceChanged()
        }
    }

    /// Local styling. Published appearance from the inbox wins over these values when
    /// `usesRemoteAppearance` is on.
    public var appearance: SupportAppearance {
        get { settings.appearance }
        set { settings.appearance = newValue }
    }

    /// Apply the appearance published from the inbox. Defaults to `true`. Remote changes apply the
    /// next time the chat opens, never mid-conversation.
    public var usesRemoteAppearance: Bool {
        get { settings.usesRemoteAppearance }
        set { settings.usesRemoteAppearance = newValue }
    }

    /// A BCP 47 language for the chat UI, for apps with their own language picker. `nil` follows
    /// the app's localization.
    public var languageOverride: String? {
        get { settings.languageOverride }
        set {
            guard newValue != settings.languageOverride else { return }
            settings.languageOverride = newValue
            engine?.scheduleSync()
            engine?.chat.rebuildRows()
        }
    }

    /// Receives SDK events on the main actor.
    public var onEvent: ((SupportEvent) -> Void)? {
        get { settings.onEvent }
        set { settings.onEvent = newValue }
    }

    // MARK: Paywalls

    /// Paywalls your app can present from offer cards. Invalid or duplicate entries are dropped;
    /// at most 20 are kept. The available ones are reported to the inbox so agents can pick them.
    public var paywalls: [SupportPaywall] {
        get { settings.paywalls }
        set {
            settings.paywalls = newValue
            refreshPaywalls()
        }
    }

    /// Called with the paywall ID when the customer taps an available offer card. Present your
    /// purchase screen from here. Without it, offer cards show as unavailable.
    public var onPaywall: ((String) -> Void)? {
        get { settings.onPaywall }
        set {
            settings.onPaywall = newValue
            engine?.chat.paywallsChanged()
        }
    }

    /// Decides whether each paywall is available to the current user, for example hiding an
    /// upgrade offer from subscribers. `nil` makes every registered paywall available.
    public var paywallAvailability: (@MainActor (String) async -> Bool)? {
        get { settings.paywallAvailability }
        set {
            settings.paywallAvailability = newValue
            refreshPaywalls()
        }
    }

    /// Re-runs `paywallAvailability`, for example after a purchase. With `invalidate`, offers show
    /// as unavailable until the check finishes.
    public func refreshPaywalls(invalidate: Bool = false) {
        if let engine {
            engine.refreshPaywalls(invalidate: invalidate)
        } else {
            availablePaywalls = Validation.paywalls(settings.paywalls)
        }
    }

    // MARK: Internals

    let settings = HostSettings()
    private(set) var engine: SupportEngine?
    private let presenter = ChatPresenter()

    private init() {
        presenter.owner = self
    }

    // MARK: - Configuration

    /// Whether `configure(appID:)` accepted an App ID in this process. It does not mean the device
    /// has registered.
    public static var isConfigured: Bool { shared.engine != nil }

    /// Configures the SDK. Call once at launch, before anything else. Calling again with the same
    /// App ID does nothing; a different App ID switches to that app's local session.
    ///
    /// - Parameters:
    ///   - appID: Your public App ID (`app_…`) from the inbox. Never pass the identity secret.
    ///   - baseURL: The service. Use `http://localhost:8787` against a local server.
    public static func configure(appID: String, baseURL: URL = YapsSupport.defaultBaseURL) {
        shared.configure(appID: appID, baseURL: baseURL)
    }

    public func configure(appID: String, baseURL: URL = YapsSupport.defaultBaseURL) {
        configure(appID: appID, baseURL: baseURL, dependencies: nil)
    }

    func configure(appID: String, baseURL: URL, dependencies: EngineDependencies?) {
        let appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard appID.hasPrefix("app_"), appID.count > 4, appID.count <= 64 else {
            if appID.hasPrefix("ids_") {
                Log.error("configure(appID:) received an identity secret. Never ship it in your app; use the public App ID (app_…).")
            } else {
                Log.error("configure(appID:) needs your public App ID, which starts with app_. It was ignored.")
            }
            return
        }
        if let engine, engine.appID == appID, engine.baseURL == baseURL { return }
        if let engine {
            presenter.dismiss()
            engine.teardown()
            unreadCount = 0
        }
        let engine = SupportEngine(appID: appID, baseURL: baseURL, settings: settings,
                                   deps: dependencies ?? .live(appID: appID))
        engine.onUnreadChange = { [weak self] count in self?.unreadCount = count }
        engine.onChatVisibilityChange = { [weak self] open in self?.isChatOpen = open }
        engine.onDismissRequested = { [weak self] in self?.presenter.dismiss() }
        engine.onOpenRequested = { [weak self] in self?.openChat() }
        engine.isChatOpen = { [weak self] in self?.isChatOpen ?? false }
        engine.onPaywallsChange = { [weak self] paywalls in self?.availablePaywalls = paywalls }
        self.engine = engine
        unreadCount = engine.unreadCount
        engine.start()
        availablePaywalls = engine.availablePaywalls
        Log.info("Configured \(appID) (SDK \(SDKInfo.version))")
        #if DEBUG
        SetupCheck.runIfRequested(engine: engine)
        #endif
    }

    private func requireEngine(_ function: String = #function) -> SupportEngine? {
        if engine == nil { Log.error("\(function) was called before YapsSupport.configure(appID:); it was ignored.") }
        return engine
    }

    // MARK: - Identity

    /// Labels this device with your user's account. These labels are unverified; use
    /// `identify(token:)` to verify them. Switching to a different user ID clears the previous
    /// user's local session.
    public func identify(userID: String, name: String? = nil, email: String? = nil) {
        requireEngine()?.identify(userID: userID, name: name, email: email)
    }

    /// Verifies the user with an HS256 JWT signed by your server (claims `user_id`, `exp`, optional
    /// `name`, `email`). Kept in memory only, so call it on every launch while signed in. Verified
    /// users share one conversation across their devices.
    public func identify(token: String) {
        requireEngine()?.identify(token: token)
    }

    /// Replaces all custom attributes shown to agents (at most 30; keys `[A-Za-z0-9_.-]{1,64}`,
    /// values up to 512 characters).
    public func setMetadata(_ metadata: [String: String]) {
        requireEngine()?.setMetadata(metadata)
    }

    /// Ends this device's support session: clears the device token, cached messages, drafts, pending
    /// sends and unread state, and closes the SDK sheet. Server history is kept. Host settings such
    /// as appearance, handlers, paywalls and the push token stay.
    public func logout() {
        requireEngine()?.logout()
    }

    /// Deletes this device's support data on the server (and the customer, conversations and files
    /// if no other device belongs to them), then clears local state and emits `.dataDeleted`. On
    /// failure it throws and keeps the session so you can retry.
    public func deleteData() async throws {
        guard let engine = requireEngine() else { throw SupportError(code: SupportError.notConfigured) }
        try await engine.deleteData()
    }

    // MARK: - Presentation

    /// Presents the chat in an SDK-owned sheet from the top view controller. If no window is ready
    /// yet (cold start), it opens once the app becomes active.
    public func openChat() {
        guard let engine = requireEngine() else { return }
        presenter.present(engine: engine)
    }

    /// Dismisses the sheet opened by `openChat()`. A ``SupportChatView`` you placed is yours to
    /// dismiss.
    public func closeChat() {
        presenter.dismiss()
    }

    // MARK: - Events

    /// Reports an app event (for example `"paywall_declined"`) to automations. Only names listed by
    /// an automation are sent; everything else stays on the device. With `opensChat`, the chat
    /// opens if an automation replies within 5 seconds.
    public func track(_ name: String, opensChat: Bool = false) {
        requireEngine()?.track(name, opensChat: opensChat)
    }

    // MARK: - Push

    /// Forwards the APNs device token from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public func setPushToken(_ token: Data, environment: PushEnvironment = .automatic) {
        requireEngine()?.setPushToken(token, environment: environment)
    }

    /// Registers with APNs if the user already allowed notifications (authorized, provisional or
    /// ephemeral). Never shows a permission prompt.
    public func registerForPushIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            Log.debug("Notifications aren't authorized; skipping APNs registration")
        }
    }

    /// Handles a notification payload. Returns `true` if it was a Support push (and refreshes unread
    /// state, opening the chat when `openChat` is true), `false` for anything else so you can route it
    /// elsewhere.
    @discardableResult
    public func handlePushNotification(userInfo: [AnyHashable: Any], openChat: Bool = true) -> Bool {
        guard let payload = SupportPushPayload.parse(userInfo) else { return false }
        guard let engine = requireEngine() else { return true }
        engine.handlePush(payload, openChat: openChat && !isChatOpen)
        return true
    }

    /// Handles a notification tap from `userNotificationCenter(_:didReceive:)`. Opens the chat for
    /// Support pushes and returns `false` for anything else.
    @discardableResult
    public func handlePushNotification(_ response: UNNotificationResponse) async -> Bool {
        handlePushNotification(userInfo: response.notification.request.content.userInfo, openChat: true)
    }

    /// Foreground presentation for `userNotificationCenter(_:willPresent:)`: `[]` while this chat is
    /// on screen, a banner otherwise, and `nil` for notifications that aren't from Support. Also
    /// refreshes unread state for Support pushes.
    public func notificationPresentationOptions(userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions? {
        guard let payload = SupportPushPayload.parse(userInfo) else { return nil }
        engine?.handlePush(payload, openChat: false)
        return SupportPushPayload.presentationOptions(for: payload, chatOpen: isChatOpen,
                                                      currentConversationId: engine?.chat.conversationId)
    }

    // MARK: - Static conveniences

    public static func identify(userID: String, name: String? = nil, email: String? = nil) {
        shared.identify(userID: userID, name: name, email: email)
    }

    public static func identify(token: String) { shared.identify(token: token) }
    public static func setMetadata(_ metadata: [String: String]) { shared.setMetadata(metadata) }
    public static func logout() { shared.logout() }
    public static func deleteData() async throws { try await shared.deleteData() }
    public static func openChat() { shared.openChat() }
    public static func closeChat() { shared.closeChat() }
    public static func track(_ name: String, opensChat: Bool = false) { shared.track(name, opensChat: opensChat) }

    public static func setPushToken(_ token: Data, environment: PushEnvironment = .automatic) {
        shared.setPushToken(token, environment: environment)
    }

    @discardableResult
    public static func handlePushNotification(userInfo: [AnyHashable: Any], openChat: Bool = true) -> Bool {
        shared.handlePushNotification(userInfo: userInfo, openChat: openChat)
    }

    public static var unreadCount: Int { shared.unreadCount }
}
