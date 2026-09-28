import Foundation
import StoreKit

/// Loads and purchases the optional "buy us a coffee" tips.
///
/// The tips are consumable in-app purchases — nothing is unlocked, so there is
/// no entitlement to track. We just finish each transaction and show a thank-you.
@MainActor
@Observable
final class TipJar {
    static let productIDs = [
        "com.nick.BallparkMatchups.tip.small",
        "com.nick.BallparkMatchups.tip.medium",
        "com.nick.BallparkMatchups.tip.large",
    ]

    /// Shared so the tip screen and the app-level transaction listener see the
    /// same state. Sharing alone doesn't keep the listener alive — see
    /// `listenForTransactions` for where it has to be started.
    static let shared = TipJar()

    /// Loaded products, sorted cheapest first.
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var purchasing: Product.ID?
    private(set) var didTip = false
    /// A purchase came back `.pending` (Ask to Buy) and is waiting on approval.
    private(set) var awaitingApproval = false
    var loadFailed = false

    func load() async {
        guard products.isEmpty else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted { $0.price < $1.price }
            loadFailed = products.isEmpty
        } catch {
            loadFailed = true
        }
    }

    /// Finishes any transaction that completes outside the purchase call
    /// (Ask to Buy approvals, retries after an interruption). It stops when the
    /// caller's `.task` is cancelled, so it must be started from the app's root
    /// view in the `App` body — never from the tip screen, or an Ask to Buy
    /// approval that lands after the screen closes is never finished.
    func listenForTransactions() async {
        for await update in Transaction.updates {
            // Finish unverified transactions too: a tip unlocks nothing, and an
            // unfinished transaction is redelivered on every launch.
            await update.unsafePayloadValue.finish()
            // Only thank someone waiting on an Ask to Buy approval. Anything else
            // here is a leftover StoreKit redelivered at launch, not a new tip.
            if case .verified = update, awaitingApproval {
                awaitingApproval = false
                didTip = true
            }
        }
    }

    func purchase(_ product: Product) async {
        purchasing = product.id
        defer { purchasing = nil }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                // Finished even if unverified, for the same reason as the listener.
                await verification.unsafePayloadValue.finish()
                if case .verified = verification {
                    didTip = true
                }
            case .pending:
                awaitingApproval = true
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            // A failed purchase is not worth interrupting the user over.
        }
    }
}
