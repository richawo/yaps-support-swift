import Foundation
import UIKit
import UserNotifications

/// Everything the engine touches outside itself, injectable for tests.
struct EngineDependencies: @unchecked Sendable {
    var transport: HTTPTransport
    var secureStore: SecureStore
    var fileStore: FileStore
    var defaults: UserDefaults
    var sleeper: APIClient.Sleeper
    var now: @Sendable () -> Date
    /// Open sockets while the chat is visible. Off in unit tests.
    var realtimeEnabled: Bool
    /// Badge, delivered notifications and lifecycle observers. Off in unit tests.
    var systemIntegration: Bool

    static func live(appID: String) -> EngineDependencies {
        EngineDependencies(
            transport: URLSessionTransport(),
            secureStore: KeychainStore(),
            fileStore: .default(appID: appID),
            defaults: .standard,
            sleeper: APIClient.defaultSleeper,
            now: { Date() },
            realtimeEnabled: true,
            systemIntegration: true
        )
    }
}

/// The SDK's core: session, identity, device sync, unread state, paywalls, appearance and the chat.
@MainActor
final class SupportEngine {
    let appID: String
    let baseURL: URL
    let api: APIClient
    let settings: HostSettings
    let deps: EngineDependencies

    // Session
    private(set) var deviceToken: String?
    private(set) var registrationId: String?
    private(set) var customer: SdkCustomer?
    private(set) var config: SdkConfig?
    private(set) var isDisabled = false

    // Staged values
    private(set) var identity: IdentityInput?
    private(set) var identityToken: String?
    private var sentIdentityToken: String?
    private(set) var metadata: [String: String]?
    private(set) var push: PushInput?
    private var synced: DeviceSnapshot?

    // Paywalls
    private(set) var availablePaywalls: [SupportPaywall] = []
    private var paywallRefresh: Task<Void, Never>?
    private var paywallsResolved = false

    // Unread
    private(set) var unreadCount = 0

    // Callbacks to the facade
    var onUnreadChange: ((Int) -> Void)?
    var onChatVisibilityChange: ((Bool) -> Void)?
    var onDismissRequested: (() -> Void)?
    var onOpenRequested: (() -> Void)?
    var isChatOpen: () -> Bool = { false }
    var onPaywallsChange: (([SupportPaywall]) -> Void)?

    private var registrationTask: Task<String, Error>?
    private var syncTask: Task<Void, Never>?
    private var syncAgain = false
    private var debounce: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var loggedUnknownApp = false

    let appearanceStore: AppearanceStore
    private(set) lazy var chat = ChatController(engine: self)

    private var tokenKey: String { "\(appID).deviceToken" }
    private static let sessionFile = "session.json"

    init(appID: String, baseURL: URL, settings: HostSettings, deps: EngineDependencies) {
        self.appID = appID
        self.baseURL = baseURL
        self.settings = settings
        self.deps = deps
        self.api = APIClient(baseURL: baseURL, appID: appID, transport: deps.transport, sleeper: deps.sleeper)
        self.appearanceStore = AppearanceStore(api: api, fileStore: deps.fileStore)
        loadPersisted()
    }

    func teardown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        chat.shutdown()
        syncTask?.cancel()
        debounce?.cancel()
        paywallRefresh?.cancel()
    }

    // MARK: - Language

    var language: String { Localization.resolve(override: settings.languageOverride) }

    /// The language the customer reads: the server's view when translation is on, else the SDK's.
    var customerLanguage: String {
        if let server = config?.translation?.customerLanguage, !server.isEmpty { return server }
        return language
    }

    var strings: Strings { Strings(language: language) }

    // MARK: - Lifecycle

    /// Starts the engine: registers (when the app is active) and wires lifecycle observers.
    func start() {
        appearanceStore.load()
        refreshPaywalls()
        guard deps.systemIntegration else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.chat.appDidEnterBackground() }
        })
        if UIApplication.shared.applicationState == .active {
            appDidBecomeActive()
        }
    }

    func appDidBecomeActive() {
        guard !isDisabled else { return }
        Task {
            await self.foregroundSync()
        }
        chat.appDidBecomeActive()
    }

    /// Registration (if needed), device sync, unread and appearance refresh.
    func foregroundSync() async {
        if deviceToken == nil {
            _ = try? await ensureRegistered()
        } else {
            await syncDevice()
        }
        if settings.usesRemoteAppearance {
            await appearanceStore.refresh()
        }
        await refreshUnread()
    }

    // MARK: - Registration (§3.2)

    @discardableResult
    func ensureRegistered() async throws -> String {
        if isDisabled { throw SupportError(code: SupportError.unknownApp, status: 404) }
        if let deviceToken { return deviceToken }
        if let registrationTask { return try await registrationTask.value }
        let task = Task { try await self.register() }
        registrationTask = task
        defer { registrationTask = nil }
        return try await task.value
    }

    private func register() async throws -> String {
        var identity = currentIdentityInput(includeToken: true)
        while true {
            let device = DeviceInfoProvider.current(language: language)
            let request = RegisterRequest(device: device, identity: identity?.isEmpty == false ? identity : nil,
                                          metadata: metadata, push: push)
            do {
                let response: RegisterResponse = try await api.send(.post, "/v1/sdk/register", body: request, token: nil)
                do {
                    try deps.secureStore.write(tokenKey, value: response.deviceToken)
                } catch {
                    Log.error("Couldn't save the device token to the Keychain; it is kept in memory for this launch.")
                }
                deviceToken = response.deviceToken
                registrationId = response.registrationId
                customer = response.customer
                apply(config: response.config)
                sentIdentityToken = identity?.token
                synced = DeviceSnapshot(device: device, identity: labelsOnly(identity), metadata: metadata, push: push,
                                        badgeEnabled: true, paywalls: nil)
                persist()
                Log.info("Registered device \(response.registrationId)")
                if needsSync() { scheduleSync(delay: 0) }
                return response.deviceToken
            } catch let error as SupportError {
                if Self.isIdentityTokenRejection(error), identity?.token != nil {
                    rejectIdentityToken(error)
                    identity?.token = nil
                    continue
                }
                if error.code == SupportError.unknownApp {
                    disable()
                }
                throw error
            }
        }
    }

    private func disable() {
        isDisabled = true
        if !loggedUnknownApp {
            loggedUnknownApp = true
            Log.error("The App ID \(appID) doesn't exist. Check it in the Support Yaps inbox under Settings. The SDK is disabled until the next configure.")
        }
    }

    static func isIdentityTokenRejection(_ error: SupportError) -> Bool {
        error.code == SupportError.identityTokenInvalid || error.code == SupportError.identityTokenExpired
            || error.code == "identity_not_configured"
    }

    private func rejectIdentityToken(_ error: SupportError) {
        Log.error("The identity token was rejected (\(error.code)). Chat continues unverified.")
        identityToken = nil
        sentIdentityToken = nil
        emit(.identityRejected(error))
    }

    /// Runs `operation` with a device token, re-registering once on `401 unauthorized` and resetting
    /// on `403 identity_mismatch` (PROTOCOL §1).
    func authorized<T>(_ operation: (String) async throws -> T) async throws -> T {
        let token = try await ensureRegistered()
        do {
            return try await operation(token)
        } catch let error as SupportError where error.code == SupportError.unauthorized && error.status == 401 {
            Log.info("Device token was rejected; registering again")
            dropDeviceToken()
            let fresh = try await ensureRegistered()
            return try await operation(fresh)
        } catch let error as SupportError where error.code == SupportError.identityMismatch {
            Log.info("This device belongs to a different verified user; starting a new session")
            resetLocalSession(keepIdentity: true)
            let fresh = try await ensureRegistered()
            return try await operation(fresh)
        }
    }

    /// Forgets the device token (the server will create a new registration and conversation).
    func dropDeviceToken() {
        deps.secureStore.delete(tokenKey)
        deviceToken = nil
        registrationId = nil
        synced = nil
        sentIdentityToken = nil
        chat.sessionChanged(clearOutbox: false)
        persist()
    }

    // MARK: - Identity (§3.3)

    func identify(userID: String, name: String?, email: String?) {
        let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty, userID.count <= 255 else {
            Log.error("identify(userID:) needs a user ID of 1–255 characters; it was ignored.")
            return
        }
        if let current = knownUserID, current != userID {
            Log.info("Switching users; clearing the previous user's local support session")
            resetLocalSession(keepIdentity: false)
            remoteLogoutIfNeeded()
        }
        identity = IdentityInput(userId: userID,
                                 name: Validation.clipped(name, max: 200, field: "name"),
                                 email: Validation.clipped(email, max: 254, field: "email"))
        persist()
        scheduleSync()
    }

    func identify(token: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.hasPrefix("ids_") else {
            Log.error("identify(token:) received an identity secret. Never ship the ids_ secret in your app; sign a JWT on your server instead.")
            return
        }
        guard token.count <= 4096 else {
            Log.error("The identity token is longer than 4,096 characters; it was ignored.")
            return
        }
        guard token != identityToken else { return }
        guard let userID = JWTClaims.userID(from: token) else {
            Log.error("The identity token has no readable user_id claim; it was ignored.")
            return
        }
        if let current = knownUserID, current != userID {
            Log.info("Identity token is for a different user; clearing the previous user's local support session")
            resetLocalSession(keepIdentity: false)
            remoteLogoutIfNeeded()
        }
        identityToken = token
        if identity?.userId != userID {
            identity = IdentityInput(userId: userID, name: identity?.name, email: identity?.email)
        }
        persist()
        scheduleSync()
    }

    private var pendingRemoteLogoutToken: String?

    private func remoteLogoutIfNeeded() {
        guard let token = pendingRemoteLogoutToken else { return }
        pendingRemoteLogoutToken = nil
        let api = self.api
        Task { try? await api.sendVoid(.post, "/v1/sdk/logout", token: token, retry: .none) }
    }

    /// The user this device currently represents, if known.
    var knownUserID: String? { customer?.userId ?? identity?.userId }

    func setMetadata(_ input: [String: String]) {
        metadata = Validation.metadata(input)
        persist()
        scheduleSync()
    }

    // MARK: - Push (§6.1)

    func setPushToken(_ token: Data, environment: PushEnvironment) {
        guard !token.isEmpty else {
            Log.error("setPushToken received an empty token; it was ignored.")
            return
        }
        guard let resolved = ProvisioningProfile.resolve(environment) else {
            Log.error("Couldn't determine the APNs environment from the provisioning profile. Pass environment: .sandbox or .production.")
            return
        }
        let input = PushInput(token: token.hexString, provider: "apns", environment: resolved)
        guard input != push else { return }
        push = input
        persist()
        Log.debug("Staged APNs token (\(resolved))")
        scheduleSync()
    }

    func badgePreferenceChanged() {
        scheduleSync()
        if settings.updatesAppBadge { applyBadge() }
    }

    // MARK: - Device sync (§3.4)

    private func labelsOnly(_ identity: IdentityInput?) -> IdentityInput? {
        guard var identity else { return nil }
        identity.token = nil
        return identity.isEmpty ? nil : identity
    }

    private func currentIdentityInput(includeToken: Bool) -> IdentityInput? {
        var value = identity ?? IdentityInput()
        if includeToken { value.token = identityToken }
        return value.isEmpty ? nil : value
    }

    private func desiredSnapshot() -> DeviceSnapshot {
        DeviceSnapshot(
            device: DeviceInfoProvider.current(language: language),
            identity: labelsOnly(identity),
            metadata: metadata,
            push: push,
            badgeEnabled: settings.updatesAppBadge,
            paywalls: paywallsResolved ? availablePaywalls.map(Self.paywallInput) : synced?.paywalls
        )
    }

    static func paywallInput(_ paywall: SupportPaywall) -> PaywallInput {
        PaywallInput(id: paywall.id, title: paywall.title,
                     products: paywall.products.isEmpty ? nil : paywall.products.map {
                         PaywallInput.Product(id: $0.id, price: $0.price, period: $0.period, trial: $0.trial)
                     })
    }

    /// The `PATCH /device` body needed to bring the server up to date, or nil if nothing changed.
    func pendingDeviceUpdate() -> DeviceUpdateRequest? {
        let desired = desiredSnapshot()
        let synced = self.synced ?? DeviceSnapshot()
        var request = DeviceUpdateRequest()
        if desired.device != synced.device { request.device = desired.device }
        if desired.identity != synced.identity || (identityToken != nil && identityToken != sentIdentityToken) {
            request.identity = currentIdentityInput(includeToken: identityToken != sentIdentityToken)
        }
        if let metadata = desired.metadata, metadata != synced.metadata { request.metadata = metadata }
        if desired.push != synced.push {
            request.push = desired.push.map { .set($0) } ?? .remove
        }
        if desired.badgeEnabled != (synced.badgeEnabled ?? true) { request.badgeEnabled = desired.badgeEnabled }
        if paywallsResolved, desired.paywalls != synced.paywalls { request.paywalls = desired.paywalls ?? [] }
        return request.isEmpty ? nil : request
    }

    private func needsSync() -> Bool { pendingDeviceUpdate() != nil }

    /// Coalesces device updates: one request in flight, re-run if something changed meanwhile.
    func scheduleSync(delay: TimeInterval = 0.3) {
        guard deviceToken != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.syncDevice()
        }
    }

    func syncDevice() async {
        if let syncTask {
            syncAgain = true
            await syncTask.value
            return
        }
        let task = Task { await self.performSync() }
        syncTask = task
        await task.value
        syncTask = nil
        if syncAgain {
            syncAgain = false
            await syncDevice()
        }
    }

    private func performSync() async {
        guard deviceToken != nil, var request = pendingDeviceUpdate() else { return }
        for _ in 0..<2 {
            let desired = desiredSnapshot()
            let tokenSent = request.identity?.token
            do {
                let response: DeviceUpdateResponse = try await authorized { token in
                    try await api.send(.patch, "/v1/sdk/device", body: request, token: token)
                }
                if let customer = response.customer { self.customer = customer }
                if let config = response.config { apply(config: config) }
                if tokenSent != nil { sentIdentityToken = tokenSent }
                var newSynced = synced ?? DeviceSnapshot()
                if let device = request.device { newSynced.device = device }
                if request.identity != nil { newSynced.identity = desired.identity }
                if let metadata = request.metadata { newSynced.metadata = metadata }
                if request.push != nil { newSynced.push = desired.push }
                if let badge = request.badgeEnabled { newSynced.badgeEnabled = badge }
                if let paywalls = request.paywalls { newSynced.paywalls = paywalls }
                synced = newSynced
                persist()
                return
            } catch let error as SupportError {
                if Self.isIdentityTokenRejection(error), request.identity?.token != nil {
                    rejectIdentityToken(error)
                    request.identity?.token = nil
                    continue
                }
                Log.debug("Device update failed: \(error.code)")
                return
            } catch {
                return
            }
        }
    }

    func apply(config: SdkConfig) {
        let previousEtag = self.config?.appearanceEtag
        self.config = config
        chat.configChanged()
        if settings.usesRemoteAppearance, let etag = config.appearanceEtag, etag != appearanceStore.etag, etag != previousEtag {
            Task { await appearanceStore.refresh() }
        }
    }

    // MARK: - Unread

    func refreshUnread() async {
        guard deviceToken != nil else { return }
        do {
            let response: UnreadResponse = try await authorized { token in
                try await api.send(.get, "/v1/sdk/unread", token: token, retry: .none)
            }
            setUnread(response.count)
        } catch {
            Log.debug("Unread refresh failed")
        }
    }

    func setUnread(_ count: Int) {
        let clamped = max(0, count)
        let changed = clamped != unreadCount
        unreadCount = clamped
        if changed {
            onUnreadChange?(clamped)
            persist()
        }
        applyBadge()
    }

    private func applyBadge() {
        guard deps.systemIntegration, settings.updatesAppBadge else { return }
        let count = unreadCount
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(count)
        }
        if count == 0 { Self.removeDeliveredSupportNotifications() }
    }

    static func removeDeliveredSupportNotifications() {
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications()
                .filter { SupportPushPayload.parse($0.request.content.userInfo) != nil }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    // MARK: - Push handling

    func handlePush(_ payload: SupportPushPayload, openChat: Bool) {
        if let badge = payload.badge, !isChatOpen() { setUnread(max(unreadCount, badge)) }
        Task { await self.refreshUnread() }
        if chat.isVisible { chat.refreshNow() }
        if openChat { onOpenRequested?() }
    }

    // MARK: - Paywalls

    func refreshPaywalls(invalidate: Bool = false) {
        let valid = Validation.paywalls(settings.paywalls)
        paywallRefresh?.cancel()
        guard let check = settings.paywallAvailability else {
            availablePaywalls = valid
            paywallsResolved = true
            onPaywallsChange?(valid)
            chat.paywallsChanged()
            scheduleSync()
            return
        }
        if invalidate {
            availablePaywalls = []
            onPaywallsChange?([])
            chat.paywallsChanged()
        }
        paywallRefresh = Task { [weak self] in
            var available: [SupportPaywall] = []
            for paywall in valid {
                if await check(paywall.id) { available.append(paywall) }
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.availablePaywalls = available
            self.paywallsResolved = true
            self.onPaywallsChange?(available)
            self.chat.paywallsChanged()
            self.scheduleSync()
        }
    }

    func isPaywallAvailable(_ id: String) -> Bool {
        settings.onPaywall != nil && availablePaywalls.contains { $0.id == id }
    }

    // MARK: - Events (§3.6)

    func track(_ name: String, opensChat: Bool) {
        guard Validation.isIdentifier(name) else {
            Log.error("track(_:) needs 1–64 characters of A–Z, a–z, 0–9, _ . -; \"\(name)\" was ignored.")
            return
        }
        let started = deps.now()
        Task {
            do {
                if self.config == nil { try await self.ensureRegistered() }
                guard let tracked = self.config?.trackedEvents, tracked.contains(name) else {
                    Log.debug("Event \(name) isn't used by any automation; it stays on the device.")
                    return
                }
                let response: TrackResponse = try await self.authorized { token in
                    try await self.api.send(.post, "/v1/sdk/events", body: TrackRequest(name: name, opensChat: opensChat), token: token)
                }
                let elapsed = self.deps.now().timeIntervalSince(started)
                if opensChat, response.openChat == true, elapsed <= 5, !self.isChatOpen(),
                   !self.deps.systemIntegration || UIApplication.shared.applicationState == .active {
                    self.onOpenRequested?()
                }
            } catch {
                Log.debug("track(\(name)) failed")
            }
        }
    }

    func emit(_ event: SupportEvent) {
        settings.onEvent?(event)
    }

    // MARK: - Logout and deletion (§3.5)

    func logout() {
        let token = deviceToken
        resetLocalSession(keepIdentity: false)
        pendingRemoteLogoutToken = nil
        onDismissRequested?()
        if let token {
            let api = self.api
            Task { try? await api.sendVoid(.post, "/v1/sdk/logout", token: token, retry: .none) }
        }
    }

    func deleteData() async throws {
        if deviceToken == nil, let stored = try? deps.secureStore.read(tokenKey) { deviceToken = stored }
        if let token = deviceToken {
            do {
                try await api.sendVoid(.delete, "/v1/sdk/device", token: token, retry: .standard)
            } catch let error as SupportError {
                let goneAlready = [SupportError.unauthorized, SupportError.unknownApp, SupportError.notFound].contains(error.code)
                guard goneAlready else { throw error }
            }
        }
        resetLocalSession(keepIdentity: false)
        pendingRemoteLogoutToken = nil
        onDismissRequested?()
        emit(.dataDeleted)
    }

    /// Clears local state. Host settings (appearance, handlers, paywalls) and the APNs token stay.
    func resetLocalSession(keepIdentity: Bool) {
        pendingRemoteLogoutToken = deviceToken
        deps.secureStore.delete(tokenKey)
        deviceToken = nil
        registrationId = nil
        customer = nil
        synced = nil
        sentIdentityToken = nil
        if !keepIdentity {
            identity = nil
            identityToken = nil
            metadata = nil
        }
        chat.sessionChanged(clearOutbox: true)
        setUnread(0)
        persist()
    }

    // MARK: - Persistence

    private func loadPersisted() {
        deviceToken = try? deps.secureStore.read(tokenKey)
        guard let session = deps.fileStore.load(PersistedSession.self, from: Self.sessionFile) else { return }
        registrationId = session.registrationId
        customer = session.customer
        config = session.config
        synced = deviceToken == nil ? nil : session.synced
        identity = session.identity
        metadata = session.metadata
        push = session.push
        unreadCount = session.unreadCount ?? 0
    }

    func persist() {
        deps.fileStore.save(PersistedSession(registrationId: registrationId, customer: customer, config: config,
                                             synced: synced, identity: identity, metadata: metadata, push: push,
                                             unreadCount: unreadCount), to: Self.sessionFile)
    }

    // MARK: - Appearance

    func resolvedAppearance() -> ResolvedAppearance {
        let strings = self.strings
        return AppearanceResolver.resolve(remote: settings.usesRemoteAppearance ? appearanceStore.remote : nil,
                                          local: settings.appearance, language: language, strings: { strings($0) })
    }
}

/// Published appearance with ETag caching (PROTOCOL §3.8).
@MainActor
final class AppearanceStore {
    private struct Cached: Codable {
        var etag: String?
        var appearance: RemoteAppearance
    }

    private let api: APIClient
    private let fileStore: FileStore
    private(set) var remote: RemoteAppearance?
    private(set) var etag: String?
    private var inFlight: Task<Void, Never>?
    private static let file = "appearance.json"

    init(api: APIClient, fileStore: FileStore) {
        self.api = api
        self.fileStore = fileStore
    }

    func load() {
        guard let cached = fileStore.load(Cached.self, from: Self.file) else { return }
        remote = cached.appearance
        etag = cached.etag
    }

    func refresh() async {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.fetch() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func fetch() async {
        var headers: [String: String] = [:]
        if let etag { headers["If-None-Match"] = etag }
        let request = api.makeRequest(.get, "/v1/sdk/appearance", token: nil, extraHeaders: headers)
        do {
            let (data, response) = try await api.perform(request, retry: .none, accept: [304])
            if response.statusCode == 304 { return }
            let appearance = try WireJSON.decoder().decode(RemoteAppearance.self, from: data)
            remote = appearance
            etag = response.value(forHTTPHeaderField: "ETag")
            fileStore.save(Cached(etag: etag, appearance: appearance), to: Self.file)
            Log.debug("Updated published appearance; it applies the next time the chat opens")
        } catch {
            Log.debug("Appearance refresh failed; keeping the previous appearance")
        }
    }

    func clear() {
        remote = nil
        etag = nil
        fileStore.remove(Self.file)
    }
}
