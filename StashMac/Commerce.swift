import Foundation
import StoreKit
import Observation

@MainActor @Observable final class Commerce {
    static let enabled = Bundle.main.object(forInfoDictionaryKey: "StashCommerceEnabled") as? Bool ?? false
    static let productIDs = ["com.kfathy.stash.personal.monthly", "com.kfathy.stash.personal.annual", "com.kfathy.stash.lifetime", "com.kfathy.stash.family.annual"]
    var products: [Product] = []
    var unlocked = !enabled
    var status = ""
    func load() async { guard Self.enabled else { return }; do { products = try await Product.products(for: Self.productIDs); await refresh() } catch { status = error.localizedDescription } }
    func purchase(_ product: Product) async { do { switch try await product.purchase() { case .success(let result): let transaction = try Self.verified(result); await transaction.finish(); await refresh(); case .pending: status = "Purchase is awaiting approval."; case .userCancelled: break; @unknown default: break } } catch { status = error.localizedDescription } }
    func refresh() async { var entitlement = false; for await result in Transaction.currentEntitlements { if let transaction = try? Self.verified(result), transaction.revocationDate == nil, Self.productIDs.contains(transaction.productID) { entitlement = true } }; unlocked = entitlement || !Self.enabled }
    func restore() async { do { try await AppStore.sync(); await refresh() } catch { status = error.localizedDescription } }
    private static func verified<T>(_ result: VerificationResult<T>) throws -> T { switch result { case .verified(let value): return value; case .unverified(_, let error): throw error } }
}
