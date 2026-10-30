import SwiftUI
import UIKit
import UserNotifications
@_spi(Preview) import YapsSupport

/// A small "Clucky" alarm app showing the usual entry point: a Settings row with an unread badge.
///
/// Launch arguments:
/// - `-YapsSupportPreview` uses a canned conversation instead of the network.
/// - `-OpenSupportChat` opens the chat on launch.
/// - `-SupportLanguage ar` sets `languageOverride`; `-PreviewDraft` seeds the composer.
/// - `-YapsSupportSetupCheck` registers and sends "Hello from setup" (Debug builds).
/// Set `YAPS_APP_ID` and optionally `YAPS_BASE_URL` (for example `http://localhost:8787`) in the
/// scheme's environment to talk to a real server.
@main
struct ExampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        YapsSupport.logLevel = .debug
        if let index = arguments.firstIndex(of: "-SupportLanguage"), arguments.indices.contains(index + 1) {
            YapsSupport.shared.languageOverride = arguments[index + 1]
        }
        #if DEBUG
        let preview = arguments.contains("-YapsSupportPreview")
        #else
        let preview = false
        #endif
        if preview {
            #if DEBUG
            YapsSupport.shared.configureForPreview(typing: !arguments.contains("-PreviewDraft"),
                                                   draftAttachments: arguments.contains("-PreviewDraft"))
            #endif
        } else {
            let baseURL = environment["YAPS_BASE_URL"].flatMap(URL.init(string:)) ?? YapsSupport.defaultBaseURL
            YapsSupport.configure(appID: environment["YAPS_APP_ID"] ?? "app_example", baseURL: baseURL)
        }
        YapsSupport.shared.identify(userID: "u_42", name: "Ada Lovelace", email: "ada@example.com")
        YapsSupport.shared.setMetadata(["plan": "free", "alarms": "3"])
        YapsSupport.shared.paywalls = [SupportPaywall(id: "yearly_offer", title: "Yearly 40% off",
                                                      products: [.init(id: "pro_yearly", price: "$29.99", period: "P1Y")])]
        YapsSupport.shared.onPaywall = { id in
            print("Present paywall \(id)")
        }
        YapsSupport.shared.onEvent = { event in
            print("Support event: \(event)")
        }
        if arguments.contains("-OpenSupportChat") {
            YapsSupport.openChat()
        }
    }

    var body: some Scene {
        WindowGroup {
            SettingsScreen()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { await YapsSupport.shared.registerForPushIfAuthorized() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        YapsSupport.shared.setPushToken(deviceToken)
    }


    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        YapsSupport.shared.notificationPresentationOptions(userInfo: notification.request.content.userInfo) ?? [.banner, .sound]
    }


    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if await YapsSupport.shared.handlePushNotification(response) { return }
        // Route other notifications here.
    }
}

struct SettingsScreen: View {
    @ObservedObject private var support = YapsSupport.shared
    @State private var snooze = 9.0
    @State private var gradualWake = true

    var body: some View {
        NavigationStack {
            List {
                Section("Alarms") {
                    Toggle("Gradual wake", isOn: $gradualWake)
                    Stepper("Snooze \(Int(snooze)) min", value: $snooze, in: 1...30)
                }
                Section {
                    Button {
                        YapsSupport.openChat()
                    } label: {
                        HStack {
                            Label("Help & Support", systemImage: "bubble.left.and.bubble.right")
                                .foregroundStyle(.primary)
                            Spacer()
                            if support.unreadCount > 0 {
                                Text("\(support.unreadCount)")
                                    .font(.footnote.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .frame(minWidth: 22, minHeight: 22)
                                    .background(Capsule().fill(.red))
                                    .accessibilityLabel("\(support.unreadCount) unread")
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    NavigationLink("Support (embedded)") {
                        SupportChatView(chrome: .embedded)
                    }
                } footer: {
                    Text("Replies usually arrive within a few hours. You’ll get a notification.")
                }
                Section {
                    Button("Log out of support", role: .destructive) { YapsSupport.shared.logout() }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
