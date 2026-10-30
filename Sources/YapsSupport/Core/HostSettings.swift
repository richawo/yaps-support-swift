import Foundation

/// Settings the host app owns. They live on the facade and survive `configure`, `logout` and
/// `deleteData`.
@MainActor
final class HostSettings {
    var appearance = SupportAppearance()
    var usesRemoteAppearance = true
    var languageOverride: String?
    var updatesAppBadge = true
    var paywalls: [SupportPaywall] = []
    var paywallAvailability: (@MainActor (String) async -> Bool)?
    var onPaywall: ((String) -> Void)?
    var onEvent: ((SupportEvent) -> Void)?

    init() {}
}

/// What the SDK has successfully told the server about this device, so `PATCH /v1/sdk/device` sends
/// only the fields that changed (PROTOCOL §3.4). Never contains the identity token.
struct DeviceSnapshot: Codable, Equatable, Sendable {
    var device: DeviceInfo?
    var identity: IdentityInput?
    var metadata: [String: String]?
    var push: PushInput?
    var badgeEnabled: Bool?
    var paywalls: [PaywallInput]?
}

/// Non-secret session state persisted between launches. The device token itself lives in the
/// Keychain.
struct PersistedSession: Codable, Sendable {
    var registrationId: String?
    var customer: SdkCustomer?
    var config: SdkConfig?
    var synced: DeviceSnapshot?
    var identity: IdentityInput?
    var metadata: [String: String]?
    var push: PushInput?
    var unreadCount: Int?
}
