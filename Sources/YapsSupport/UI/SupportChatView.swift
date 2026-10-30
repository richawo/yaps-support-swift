import SwiftUI
import UIKit

/// The Support chat as a SwiftUI view.
///
/// - `SupportChatView()` brings its own navigation bar. Use it in a sheet, full-screen cover or tab.
/// - `SupportChatView(chrome: .embedded)` uses your navigation stack. Use it as a
///   `NavigationLink` destination.
///
/// Configure the SDK before creating the view. Do not also call `openChat()` for the same action.
public struct SupportChatView: View {
    public enum Chrome: Sendable {
        /// Wraps the chat in its own `NavigationStack` with a title and, when presented, a close
        /// button.
        case standalone
        /// Uses the surrounding navigation context.
        case embedded
    }

    private let chrome: Chrome
    private let onClose: (() -> Void)?

    public init(chrome: Chrome = .standalone) {
        self.chrome = chrome
        self.onClose = nil
    }

    /// A standalone chat whose close button calls `onClose`.
    public init(onClose: @escaping () -> Void) {
        self.chrome = .standalone
        self.onClose = onClose
    }

    init(chrome: Chrome, onClose: (() -> Void)?) {
        self.chrome = chrome
        self.onClose = onClose
    }

    public var body: some View {
        if let engine = YapsSupport.shared.engine {
            ChatRoot(engine: engine, chrome: chrome, onClose: onClose)
        } else {
            NotConfiguredView()
        }
    }
}

/// The Support chat for UIKit. Present it modally, or create it with `embedded: true` to push it
/// onto your navigation controller.
@MainActor
public final class SupportChatViewController: UIHostingController<AnyView> {
    /// - Parameter embedded: `true` when pushing onto your `UINavigationController`; `false`
    ///   (default) for modal presentation with the chat's own navigation bar and close button.
    public init(embedded: Bool = false) {
        super.init(rootView: AnyView(EmptyView()))
        let close: (() -> Void)? = embedded ? nil : { [weak self] in self?.dismiss(animated: true) }
        rootView = AnyView(SupportChatView(chrome: embedded ? .embedded : .standalone, onClose: close))
        if embedded, let engine = YapsSupport.shared.engine {
            title = engine.resolvedAppearance().title
        }
    }

    init(engine: SupportEngine, onClose: @escaping () -> Void) {
        super.init(rootView: AnyView(ChatRoot(engine: engine, chrome: .standalone, onClose: onClose)))
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

private struct NotConfiguredView: View {
    var body: some View {
        let strings = Strings(language: Localization.resolve(override: YapsSupport.shared.languageOverride))
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: strings("notConfigured"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .onAppear { Log.error("SupportChatView appeared before YapsSupport.configure(appID:).") }
    }
}

/// Presents the chat as an SDK-owned sheet from the top view controller.
@MainActor
final class ChatPresenter {
    weak var owner: YapsSupport?
    private weak var presented: UIViewController?
    private var pendingObserver: NSObjectProtocol?

    func present(engine: SupportEngine) {
        if let presented, presented.presentingViewController != nil, !presented.isBeingDismissed { return }
        if owner?.isChatOpen == true { return }
        guard let top = Self.topViewController() else {
            // Cold start: no window yet. Open once the app is active.
            guard pendingObserver == nil else { return }
            pendingObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let observer = self.pendingObserver { NotificationCenter.default.removeObserver(observer) }
                    self.pendingObserver = nil
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        self.present(engine: engine)
                    }
                }
            }
            return
        }
        let controller = SupportChatViewController(engine: engine) { [weak self] in self?.dismiss() }
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = nil
        }
        top.present(controller, animated: true)
        presented = controller
    }

    func dismiss() {
        if let observer = pendingObserver {
            NotificationCenter.default.removeObserver(observer)
            pendingObserver = nil
        }
        guard let presented else { return }
        presented.presentingViewController?.dismiss(animated: true)
        self.presented = nil
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first { $0.activationState == .foregroundInactive }
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              var top = window.rootViewController else { return nil }
        while true {
            if let presented = top.presentedViewController, !presented.isBeingDismissed {
                top = presented
            } else if let navigation = top as? UINavigationController, let visible = navigation.visibleViewController, visible !== top {
                if visible === navigation.presentedViewController { break }
                top = visible
            } else if let tabs = top as? UITabBarController, let selected = tabs.selectedViewController {
                top = selected
            } else {
                break
            }
        }
        return top
    }
}
