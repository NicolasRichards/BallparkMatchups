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

    /// Shared because the transaction listener has to outlive any one screen.
    /// Running `listenForTransactions` from a sheet's `.task` cancelled it the
    /// moment the sheet closed, so an Ask to Buy approval that landed later was
    /// never finished and StoreKit kept redelivering it.
    static let shared = TipJar()

    /// Loaded products, sorted cheapest first.
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var purchasing: Product.ID?
    private(set) var didTip = false
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
    /// (Ask to Buy approvals, retries after an interruption). Runs for the
    /// lifetime of the caller's `.task`.
    func listenForTransactions() async {
        for await update in Transaction.updates {
            guard case .verified(let transaction) = update else { continue }
            await transaction.finish()
            didTip = true
        }
    }

    func purchase(_ product: Product) async {
        purchasing = product.id
        defer { purchasing = nil }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    didTip = true
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            // A failed purchase is not worth interrupting the user over.
        }
    }
}
