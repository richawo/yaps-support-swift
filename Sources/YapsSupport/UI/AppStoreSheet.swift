import StoreKit
import UIKit

/// Opens a promoted app's App Store page in-app (`SKStoreProductViewController`) above the chat,
/// falling back to the store URL when there's no App Store ID, no window, or the product fails to
/// load (§5 App promo card).
@MainActor
enum AppStoreSheet {
    private static let delegate = Delegate()

    static func open(appStoreId: String?, fallback: URL?) {
        guard let appStoreId, let number = Int(appStoreId), let top = ChatPresenter.topViewController() else {
            if let fallback { UIApplication.shared.open(fallback) }
            return
        }
        let store = SKStoreProductViewController()
        store.delegate = delegate
        top.present(store, animated: true)
        Task { @MainActor in
            do {
                try await store.loadProduct(withParameters: [SKStoreProductParameterITunesItemIdentifier: NSNumber(value: number)])
            } catch {
                Log.info("App Store sheet failed to load; opening the store link instead")
                store.presentingViewController?.dismiss(animated: true, completion: nil)
                if let fallback { UIApplication.shared.open(fallback, options: [:], completionHandler: nil) }
            }
        }
    }

    private final class Delegate: NSObject, SKStoreProductViewControllerDelegate {
        func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
            MainActor.assumeIsolated { viewController.presentingViewController?.dismiss(animated: true, completion: nil) }
        }
    }
}
