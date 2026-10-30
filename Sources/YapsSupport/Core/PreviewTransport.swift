import Foundation
import UIKit

#if DEBUG
/// A canned server for previews, screenshots and UI work without a backend. DEBUG builds only, and
/// only through `@_spi(Preview)`.
final class PreviewTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seq = 10
    private let imageURL: String
    private let iconURL: String

    init(imageURL: URL, iconURL: URL) {
        self.imageURL = imageURL.absoluteString
        self.iconURL = iconURL.absoluteString
    }

    private static func iso(_ minutesAgo: Double) -> String {
        WireJSON.formatDate(Date().addingTimeInterval(-minutesAgo * 60))
    }

    private func conversation() -> [String: Any] {
        let agent: [String: Any] = ["type": "agent", "id": "usr_3", "name": "Frederick"]
        let messages: [[String: Any]] = [
            ["id": "msg_1", "seq": 1, "author": ["type": "customer"], "text": "The alarm volume resets to low every morning. Is that a bug?", "createdAt": Self.iso(26)],
            ["id": "msg_2", "seq": 2, "author": agent, "text": "Not a bug, but it’s confusing. iOS lowers alarms while a Focus is on.", "createdAt": Self.iso(24)],
            ["id": "msg_3", "seq": 3, "author": agent, "text": "Settings → Focus → Sleep → Options, then turn off “Dim Lock Screen”. Here’s where it is:", "createdAt": Self.iso(24)],
            ["id": "msg_4", "seq": 4, "author": agent, "text": "", "createdAt": Self.iso(23),
             "attachments": [["id": "upl_1", "kind": "image", "contentType": "image/jpeg", "url": imageURL, "thumbnailUrl": imageURL,
                              "width": 1200, "height": 900, "size": 183022, "filename": "focus-settings.jpg"]]],
            ["id": "msg_5", "seq": 5, "author": ["type": "customer"], "text": "That fixed it. Max volume at 6:30 this morning.", "createdAt": Self.iso(9)],
            ["id": "msg_6", "seq": 6, "author": ["type": "customer"], "text": "Thanks Frederick!", "createdAt": Self.iso(9)],
            ["id": "msg_7", "seq": 7, "kind": "card", "author": agent,
             "text": "Glad it’s sorted. If Clucky got you up on time, a quick rating helps a small team a lot.", "createdAt": Self.iso(4),
             "card": ["type": "review", "buttonLabel": "Rate Clucky", "url": "https://apps.apple.com/app/id6450000000?action=write-review", "available": true]],
            ["id": "msg_8", "seq": 8, "kind": "card", "author": agent, "text": "And since you asked about the yearly plan earlier:", "createdAt": Self.iso(3),
             "card": ["type": "offer", "title": "Clucky Pro, yearly · 40% off", "buttonLabel": "See the offer", "paywallId": "yearly_offer", "available": true]],
            ["id": "msg_9", "seq": 9, "kind": "card", "author": agent, "text": "You mentioned exams. Our flashcard app might help too.", "createdAt": Self.iso(2),
             "card": ["type": "app", "title": "Stacked", "body": "Flashcards that plan your revision for you.", "buttonLabel": "Get it",
                      "iconUrl": iconURL, "promotedAppId": "app_2", "appStoreId": "6450000001",
                      "url": "https://apps.apple.com/app/id6450000001", "installed": false, "available": true]],
            ["id": "msg_10", "seq": 10, "kind": "card", "author": agent, "text": "And here’s 20% off yearly with your student discount.", "createdAt": Self.iso(1),
             "card": ["type": "code", "title": "Student discount", "body": "20% off yearly for students.", "code": "STUDENT20",
                      "campaignId": "cmp_1", "platform": "ios", "buttonLabel": "Redeem",
                      "url": "https://apps.apple.com/redeem?ctx=offercodes&id=6450000000&code=STUDENT20",
                      "expiresAt": WireJSON.formatDate(Date().addingTimeInterval(60 * 86_400)), "available": true]],
        ].map { message in
            var message = message
            message["conversationId"] = "cnv_1"
            message["kind"] = message["kind"] ?? "text"
            message["attachments"] = message["attachments"] ?? []
            return message
        }
        return ["conversation": ["id": "cnv_1", "status": "open", "lastSeq": 10, "customerReadSeq": 10, "agentReadSeq": 6, "unread": 0,
                                 "createdAt": Self.iso(26)],
                "messages": messages, "hasMore": false]
    }

    private let config: [String: Any] = [
        "appId": "app_preview", "appName": "Clucky", "verifiedOnly": false, "blocked": false, "trackedEvents": [String](),
        "translation": ["enabled": false], "teamDisplay": ["showNames": true, "showPhotos": true],
        "uploads": ["images": true, "files": true], "pollIntervalSeconds": 60,
    ]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(nanoseconds: 150_000_000)
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        var status = 200
        var body: Any = [String: Any]()
        switch (method, path) {
        case ("POST", "/v1/sdk/register"):
            status = 201
            body = ["deviceToken": "dt_reg_preview_secret", "registrationId": "reg_preview",
                    "customer": ["id": "cus_preview", "verified": true], "config": config]
        case ("PATCH", "/v1/sdk/device"):
            body = ["customer": ["id": "cus_preview", "verified": true], "config": config]
        case ("GET", "/v1/sdk/conversation"):
            body = conversation()
        case ("GET", "/v1/sdk/unread"):
            body = ["count": 0, "conversationId": "cnv_1"]
        case ("POST", "/v1/sdk/messages"):
            let sent = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
            let next: Int = lock.withLock { seq += 1; return seq }
            status = 201
            body = ["message": ["id": "msg_\(next)", "conversationId": "cnv_1", "seq": next, "clientId": sent["clientId"] ?? "",
                                "author": ["type": "customer"], "kind": "text", "text": sent["text"] ?? "", "attachments": [Any](),
                                "createdAt": WireJSON.formatDate(Date())]]
        case ("GET", "/v1/sdk/appearance"):
            status = 304
        default:
            status = 204
        }
        let data = status == 204 || status == 304 ? Data() : try JSONSerialization.data(withJSONObject: body)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func upload(_ request: URLRequest, body: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
        progress(1)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    /// A drawn stand-in for the promoted app's icon: a fanned stack of cards on a gradient.
    static func makePreviewIcon(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("preview-app-icon.png")
        let size = CGSize(width: 180, height: 180)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(red: 0.36, green: 0.42, blue: 0.98, alpha: 1).cgColor,
                          UIColor(red: 0.62, green: 0.32, blue: 0.95, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            for (index, alpha) in [0.4, 0.7, 1.0].enumerated() {
                let inset = CGFloat(2 - index) * 12
                let card = CGRect(x: 40 + inset, y: 46 + CGFloat(index) * 16, width: 100 - inset * 2, height: 72)
                UIColor.white.withAlphaComponent(alpha).setFill()
                UIBezierPath(roundedRect: card, cornerRadius: 14).fill()
            }
        }
        try? image.pngData()?.write(to: url)
        return url
    }

    /// A drawn stand-in for a settings screenshot, so previews need no network.
    static func makePreviewImage(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("preview-focus-settings.jpg")
        let size = CGSize(width: 1200, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let rows = ["Allowed Notifications", "Focus Status", "Dim Lock Screen", "Silence Notifications"]
            for (index, title) in rows.enumerated() {
                let rect = CGRect(x: 80, y: 140 + CGFloat(index) * 170, width: 1040, height: 140)
                UIColor.white.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 34).fill()
                (title as NSString).draw(at: CGPoint(x: 130, y: rect.midY - 30),
                                         withAttributes: [.font: UIFont.systemFont(ofSize: 52, weight: .medium), .foregroundColor: UIColor.black])
                let toggle = CGRect(x: rect.maxX - 230, y: rect.midY - 42, width: 150, height: 84)
                (index == 2 ? UIColor(white: 0.82, alpha: 1) : UIColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)).setFill()
                UIBezierPath(roundedRect: toggle, cornerRadius: 42).fill()
                UIColor.white.setFill()
                let knobX = index == 2 ? toggle.minX + 6 : toggle.maxX - 78
                UIBezierPath(ovalIn: CGRect(x: knobX, y: toggle.minY + 6, width: 72, height: 72)).fill()
            }
        }
        try? image.jpegData(compressionQuality: 0.85)?.write(to: url)
        return url
    }
}

extension YapsSupport {
    /// Configures the SDK against a canned conversation (no network). DEBUG builds only.
    @_spi(Preview)
    public func configureForPreview(typing: Bool = true, draftAttachments: Bool = false) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yaps-support-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = PreviewTransport.makePreviewImage(in: directory)
        let iconURL = PreviewTransport.makePreviewIcon(in: directory)
        UserDefaults.standard.removePersistentDomain(forName: "yaps-support-preview")
        let deps = EngineDependencies(transport: PreviewTransport(imageURL: imageURL, iconURL: iconURL), secureStore: MemorySecureStore(),
                                      fileStore: FileStore(directory: directory),
                                      defaults: UserDefaults(suiteName: "yaps-support-preview") ?? .standard,
                                      sleeper: APIClient.defaultSleeper, now: { Date() }, realtimeEnabled: false, systemIntegration: true)
        configure(appID: "app_preview", baseURL: URL(string: "https://preview.support.yaps.ai")!, dependencies: deps)
        if draftAttachments, let chat = engine?.chat {
            let preview = UIImage(contentsOfFile: imageURL.path)
            let data = (try? Data(contentsOf: imageURL)) ?? Data()
            chat.seededAttachments = [
                DraftAttachment(kind: .image, data: data, contentType: "image/jpeg", filename: "IMG_0412.jpg",
                                width: 1200, height: 900, preview: preview),
                DraftAttachment(kind: .file, data: Data(count: 48_200), contentType: "text/plain", filename: "clucky-alarm-debug.log"),
            ]
            chat.draft = "Here’s the log from this morning"
        }
        if typing {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self.engine?.chat.handle(.state(agentTyping: true, agentReadSeq: nil, customerReadSeq: nil))
            }
        }
    }
}
#endif
