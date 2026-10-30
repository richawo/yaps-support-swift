import Foundation
import UserNotifications

/// A recognised Support Yaps push (PROTOCOL §6.1).
struct SupportPushPayload: Equatable, Sendable {
    var conversationId: String
    var messageId: String?
    var badge: Int?

    /// Recognises the APNs shape (`support` dictionary with a `conversationId`) and, for apps that
    /// forward FCM data messages on iOS, the FCM shape (`support == "1"`). Anything else is nil so the
    /// host can route it elsewhere.
    static func parse(_ userInfo: [AnyHashable: Any]) -> SupportPushPayload? {
        if let support = userInfo["support"] as? [String: Any] {
            guard let conversationId = support["conversationId"] as? String, !conversationId.isEmpty else { return nil }
            let aps = userInfo["aps"] as? [String: Any]
            return SupportPushPayload(conversationId: conversationId,
                                      messageId: support["messageId"] as? String,
                                      badge: (aps?["badge"] as? NSNumber)?.intValue)
        }
        if let flag = userInfo["support"] as? String, flag == "1" {
            guard let conversationId = userInfo["conversationId"] as? String, !conversationId.isEmpty else { return nil }
            return SupportPushPayload(conversationId: conversationId,
                                      messageId: userInfo["messageId"] as? String,
                                      badge: (userInfo["badge"] as? String).flatMap(Int.init))
        }
        return nil
    }

    /// Foreground presentation: nothing while this chat is on screen, otherwise a banner.
    static func presentationOptions(for payload: SupportPushPayload?, chatOpen: Bool,
                                    currentConversationId: String?) -> UNNotificationPresentationOptions? {
        guard let payload else { return nil }
        if chatOpen && (currentConversationId == nil || currentConversationId == payload.conversationId) { return [] }
        return [.banner, .list, .sound, .badge]
    }
}
