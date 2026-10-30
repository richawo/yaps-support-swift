import Foundation

#if DEBUG
/// Launch with `-YapsSupportSetupCheck` (Debug builds only) to register this device, send
/// "Hello from setup" and print PASS or FAIL to the console.
@MainActor
enum SetupCheck {
    static let argument = "-YapsSupportSetupCheck"

    static func runIfRequested(engine: SupportEngine, arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains(argument) else { return }
        Task { await run(engine: engine) }
    }

    @discardableResult
    static func run(engine: SupportEngine) async -> Bool {
        Log.setupCheck("Setup check: starting for \(engine.appID) at \(engine.baseURL.absoluteString)")
        do {
            try await engine.ensureRegistered()
            Log.setupCheck("Setup check: registered device \(engine.registrationId ?? "?")")
            let clientId = ULID.make()
            let response: SendMessageResponse = try await engine.authorized { token in
                try await engine.api.send(.post, "/v1/sdk/messages",
                                          body: SendMessageRequest(clientId: clientId, text: "Hello from setup", attachments: nil),
                                          token: token, retry: .standard)
            }
            Log.setupCheck("Setup check: PASS. Sent message \(response.message.id) in \(response.message.conversationId). Open the inbox to reply.")
            return true
        } catch let error as SupportError {
            Log.setupCheck("Setup check: FAIL (\(error.code), HTTP \(error.status)). \(hint(for: error))")
            return false
        } catch {
            Log.setupCheck("Setup check: FAIL (\(error.localizedDescription))")
            return false
        }
    }

    private static func hint(for error: SupportError) -> String {
        switch error.code {
        case SupportError.unknownApp: return "The App ID doesn't exist. Copy it from the inbox under Settings."
        case SupportError.connectionFailed: return "Couldn't reach the server. Check the network and baseURL."
        case SupportError.blocked: return "This device is blocked in the inbox."
        case SupportError.verificationRequired: return "The app only accepts verified users. Call identify(token:) first."
        case SupportError.rateLimited: return "Rate limited. Try again in a few seconds."
        default: return "See the Support Yaps docs for this error code."
        }
    }
}
#endif
