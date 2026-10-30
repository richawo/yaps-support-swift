# YapsSupport for iOS

In-app support chat for Support Yaps (https://support.yaps.ai). A native SwiftUI chat your users
open from your app, answered from the Support Yaps inbox, Telegram or the operator app.

- iOS 16+, Swift 6 (strict concurrency clean), no third-party dependencies
- SwiftUI and UIKit, light and dark mode, Dynamic Type, VoiceOver, right-to-left
- 22 languages: en, es, fr, de, it, pt-BR, nl, sv, pl, tr, ru, uk, ar, he, hi, ja, ko, zh-Hans,
  zh-Hant, id, vi, th
- Live updates over a WebSocket while the chat is on screen, push notifications when it isn't
- Photos (up to 5), camera, and PDF/TXT/ZIP/LOG files; messages survive going offline
- Verified identity across devices; review, offer, app promo and code cards; automations from app
  events
- A privacy manifest (`PrivacyInfo.xcprivacy`) ships inside the package

## Install

**Xcode:** File → Add Package Dependencies…, enter `https://github.com/richawo/yaps-support-swift`,
choose "Up to Next Major Version" from `1.0.0`, and add the `YapsSupport` library to your app target.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/richawo/yaps-support-swift", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "YapsSupport", package: "yaps-support-swift")]),
]
```

## Quick start

```swift
import SwiftUI
import YapsSupport

@main
struct MyApp: App {
    init() {
        YapsSupport.configure(appID: "app_YOUR_APP_ID")   // public; safe to ship
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct SupportRow: View {
    @ObservedObject private var support = YapsSupport.shared

    var body: some View {
        Button {
            YapsSupport.openChat()
        } label: {
            LabeledContent("Help & Support") {
                if support.unreadCount > 0 { Text("\(support.unreadCount)").monospacedDigit() }
            }
        }
    }
}
```

That's a working chat. The App ID is in the inbox under **Settings → your app**. Calling
`configure` again with the same ID does nothing.

### Ways to show the chat

| | |
|---|---|
| `YapsSupport.openChat()` / `closeChat()` | An SDK-owned sheet from the top view controller. On a cold start it waits until the app is active. |
| `SupportChatView()` | SwiftUI, with its own navigation bar. Use in a `.sheet`, a full-screen cover or a tab. |
| `SupportChatView(chrome: .embedded)` | SwiftUI inside your `NavigationStack` (for example a `NavigationLink` destination). |
| `SupportChatViewController()` | UIKit, for modal presentation. `SupportChatViewController(embedded: true)` to push it. |

`YapsSupport.shared.isChatOpen` tells you whether chat content is on screen (any of the above).

### Check your setup

In a Debug build, add `-YapsSupportSetupCheck` to the scheme's launch arguments. On launch the SDK
registers the device, sends "Hello from setup" and prints `PASS` or `FAIL` with a reason to the
Xcode console. Reply from the inbox to see the round trip.

## Identify your users

```swift
// After sign-in and on every launch while signed in
YapsSupport.shared.identify(userID: user.id, name: user.displayName, email: user.email)
YapsSupport.shared.setMetadata(["plan": "pro", "seats": "5"])   // replaces all metadata

// At sign-out
YapsSupport.shared.logout()

// When the account is deleted: await this before discarding the account
try await YapsSupport.shared.deleteData()
```

`identify(userID:…)` labels the conversation for your team. Labels alone are unverified, and each
device keeps its own conversation. Switching to a different user ID clears the previous user's local
session automatically. Metadata allows 30 entries (keys `[A-Za-z0-9_.-]{1,64}`, values ≤ 512
characters); invalid entries are logged and left out.

`logout()` clears the device token, cached messages, drafts, pending sends and unread state, and
closes the SDK sheet. Server history is kept. Your settings (appearance, handlers, paywalls) and the
APNs token stay, so you don't need to re-forward the token.

`deleteData()` deletes this device's registration and, if no other device belongs to the customer,
their conversations and files. On failure it throws a `SupportError` and keeps the session so you
can retry.

## Identity verification

Verified users are one person across all their devices, and across your other apps if you link
them: every device that presents a valid token for the same `user_id` shares one customer and one
conversation.

1. In the inbox, open **Settings → your app → Identity** and copy the identity secret (`ids_…`).
   Keep it on your server. **Never ship it in the app.**
2. On your server, sign an HS256 JWT with the claims `user_id` (required), `exp` (required) and
   optionally `name`, `email`, `nbf`:

   ```js
   import jwt from "jsonwebtoken";
   const token = jwt.sign({ user_id: user.id, email: user.email, name: user.name },
                          process.env.SUPPORT_IDENTITY_SECRET, { algorithm: "HS256", expiresIn: "7d" });
   ```

3. In the app, pass it after sign-in and on every launch (it's kept in memory only):

   ```swift
   YapsSupport.shared.identify(token: tokenFromYourServer)
   ```

If the server rejects the token (invalid or expired), the SDK drops it, keeps chatting unverified
and emits `.identityRejected(SupportError)`. Fetch a fresh token for `identity_token_expired`.
To accept only verified users, turn on **Verified users only** in the inbox; unverified devices can
read but see "Sign in to send messages".

## Push notifications

The SDK never asks for notification permission and never replaces your delegates. You keep your
own permission flow; the SDK forwards the token and recognises its own pushes.

1. Add the **Push Notifications** capability. Upload your APNs key (`.p8`, Key ID, Team ID, Bundle
   ID) in the inbox under **Settings → your app → Push**.
2. Register when permission is already granted, and forward the token:

```swift
import UIKit
import UserNotifications
import YapsSupport

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { await YapsSupport.shared.registerForPushIfAuthorized() }   // never prompts
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        YapsSupport.shared.setPushToken(deviceToken)   // environment: .automatic
    }

    // Foreground: nothing while the chat is open, a banner otherwise, nil for other pushes.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        YapsSupport.shared.notificationPresentationOptions(userInfo: notification.request.content.userInfo)
            ?? [.banner, .sound]   // your policy for other notifications
    }

    // Tap: opens the chat for Support pushes, returns false for everything else.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if await YapsSupport.shared.handlePushNotification(response) { return }
        // route your other notifications
    }
}
```

In SwiftUI, connect it with `@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate`. Keep
the delegate on the main actor as shown: a `nonisolated` async delegate method completes off the main
thread, which crashes on tap.

- `setPushToken(_:environment:)` with `.automatic` reads `aps-environment` from the embedded
  provisioning profile (sandbox on the simulator, production without a profile). Pass `.sandbox` or
  `.production` to override.
- `handlePushNotification(userInfo:openChat:)` is the synchronous variant. Pass `openChat: false`
  when you route to your own Support screen.
- By default the SDK sets the app icon badge to the unread count and removes delivered Support
  notifications when it reaches zero. Set `YapsSupport.shared.updatesAppBadge = false` if your app
  owns the badge; the server then stops sending a badge value.
- If you send offer cards, say in your permission flow that notifications can include offers (App
  Review guideline 4.5.4).

## Paywalls and offer cards

Agents can send an offer card that opens a paywall your app already has. Register what you can show
and handle the tap:

```swift
YapsSupport.shared.paywalls = [
    SupportPaywall(id: "yearly_offer", title: "Yearly 40% off",
                   products: [.init(id: "pro_yearly", price: "$29.99", period: "P1Y", trial: "P1W")]),
]
YapsSupport.shared.onPaywall = { paywallID in
    PaywallPresenter.present(paywallID)   // present above the chat
}
// Optional: hide offers that don't apply to this user, for example subscribers
YapsSupport.shared.paywallAvailability = { paywallID in
    await !Subscriptions.shared.isSubscribed
}
// After a purchase or a subscription change
YapsSupport.shared.refreshPaywalls(invalidate: true)
```

Available paywalls are reported to the inbox (via `PATCH /v1/sdk/device`), so agents only pick ones
this device can open. A card whose paywall isn't available, or with no `onPaywall` handler, shows as
"No longer available". IDs are 1–64 characters of `[A-Za-z0-9_.-]`, titles up to 60; at most 20 are
kept. The title and products are shown to agents only.

Review cards open the App Store review page the agent's card carries. They never trigger the
in-app rating prompt.

## App promo and code cards

Both need no code in your app. The server resolves each card for this device before it arrives.

**App promo cards** recommend another app from your organisation: its icon, name, a one-line
pitch and **Get it**. The tap opens the App Store sheet in-app (`SKStoreProductViewController`)
on top of the chat, or the App Store page if the card has no App Store ID or the sheet can't load.
When the customer already uses that app (a verified user with the same user ID there), the card
says "You already have it" and has no button. A promo with no store link for iOS shows as a
plain message.

**Code cards** show a discount code in a monospaced, selectable box:

| State | Shows |
|---|---|
| Redeemable here | **Copy** and **Redeem**, which opens Apple's offer-code sheet with the code filled in. The expiry date, if any. |
| Redeemable elsewhere | **Copy** and a hint: "Redeem on Android", "Redeem on the web" or "Redeem on iPhone". |
| Past `expiresAt` | The code struck through, "Expired", no buttons. An open thread updates when the code expires. |

Copy puts the code on the pasteboard, plays a success haptic and shows "Copied" for a moment;
VoiceOver announces it and reads the code character by character. Copy and Redeem are recorded
for your team's stats (`POST /v1/sdk/actions/:messageId`).

Both cards follow your appearance, light and dark mode, Dynamic Type and right-to-left layouts,
and are translated into all 22 languages. Card types the SDK doesn't know yet show as plain
messages.

## Automations

```swift
YapsSupport.shared.track("paywall_declined")
YapsSupport.shared.track("onboarding_completed", opensChat: true)
```

Only events an automation listens for (`config.trackedEvents`) leave the device. With
`opensChat: true`, the chat opens if an automation replies within 5 seconds while the app is active.

## Appearance

```swift
var look = SupportAppearance()
look.accentColor = .orange          // your bubbles, send button; ink is picked for contrast
look.title = "Help"
look.welcomeTitle = "Stuck on an alarm?"
look.welcomeText = "Frederick and Ines usually reply within a few hours."
look.fontDesign = .rounded
look.cornerStyle = .soft
look.welcomeIcon = .symbol("alarm.fill")
YapsSupport.shared.appearance = look
```

Everything can also be published from the inbox. **Precedence: published (remote) > your local
value > SDK default.** Published appearance is cached with its ETag and applies the next time the
chat opens, never mid-conversation. Set `usesRemoteAppearance = false` to use local values only.
Remote text is picked by language, then English, before falling back to your local text.

The chat's language follows your app's own localization (so an English-only app shows an English
chat even on an Arabic device), falling back to English. `languageOverride` sets it explicitly (a
BCP 47 tag) for apps with their own language picker; Arabic and Hebrew lay out right to left.

## Events and logging

```swift
YapsSupport.shared.onEvent = { event in
    switch event {
    case .messageSent: Analytics.log("support_message_sent")
    case .identityRejected(let error): Log.warn("Support identity rejected: \(error.code)")
    default: break
    }
}
YapsSupport.logLevel = .debug
YapsSupport.logHandler = { level, line in MyLogger.log(level, line) }
```

Events: `chatOpened`, `chatClosed`, `messageSent`, `messageReceived`, `imageSent`, `reviewOpened`,
`paywallOpened`, `appPromoOpened`, `codeCopied`, `codeOpened`, `dataDeleted`,
`identityRejected(SupportError)`. They never carry message text, codes or user identifiers, and
log lines never contain message text, identity or metadata values, or tokens. Switch with a
`default` case, since later SDK versions may add events.

## How it behaves

- **Registration** happens when the app is first active after `configure`. The device token lives
  in the Keychain (`kSecAttrAccessibleAfterFirstUnlock`); on `401` the SDK registers again.
- **Live updates**: a WebSocket only while chat content is visible and the app is active, with
  `hello`/resume, pings every 25 s, jittered reconnects (1–30 s) and REST polling when sockets are
  blocked.
- **Sending**: every message is written to an outbox first (JSON in Application Support, excluded
  from backups) with a ULID client ID, so retries never duplicate. Retries back off 1 s, 2 s, 4 s…
  and the message shows **Not delivered · Retry** after 5 attempts or a definitive rejection.
- **History**: the last 200 messages are cached for instant display; scrolling to the top loads
  older pages. Drafts are kept across launches.
- **Attachments**: photos are downscaled to ≤ 2,048 px and ≤ 1 MiB JPEG before upload, with
  progress. Files: PDF, TXT, ZIP or LOG up to 10 MiB. The camera option appears when your
  Info.plist has `NSCameraUsageDescription`.
- **Translation**: when an agent's reply has a translation in the customer's language, the chat
  shows it.

## Example app

`Example/` is a small SwiftUI "Clucky" app with a Settings row and an unread badge.

```sh
cd sdk/ios/Example
xcodegen generate         # creates YapsSupportExample.xcodeproj
open YapsSupportExample.xcodeproj
```

Launch arguments: `-YapsSupportPreview` (a canned conversation, no network), `-OpenSupportChat`
and `-YapsSupportSetupCheck`. Set `YAPS_APP_ID` and `YAPS_BASE_URL` (for example
`http://localhost:8787`) in the scheme's environment to use a real server.

## Development

```sh
cd sdk/ios
xcodebuild -scheme YapsSupport -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme YapsSupport -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The tests decode every fixture in `protocol/fixtures` (copied into `Tests/YapsSupportTests/Fixtures`;
a test fails if the copies drift from the source). The wire contract is `protocol/PROTOCOL.md`.
