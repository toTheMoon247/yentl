//
//  PurchaseService.swift
//  Yentl
//
//  Phase 9: the StoreKit side of the match-unlock fee, via RevenueCat.
//  (Internal symbol names still read `dateFee*` — harmless, pre-rename; the
//  product is `match_unlock`. See docs/monetization-model.md.)
//
//  Lives in the app target (not YentlShared) on purpose: the RevenueCat SDK
//  is linked only into the consumer app — the matchmaker app takes no
//  payments and must not carry the dependency. The backend-facing half
//  (record-payment / is_match_paid / own-payment reads) is YentlShared's
//  PaymentService; this file owns everything that touches the RevenueCat SDK.
//
//  Identity: the RevenueCat app-user-id is the Supabase user id, lowercased —
//  the exact convention OneSignal.login and Stream connect already use (see
//  ContentView's auth-lifecycle task). record-payment verifies purchases by
//  looking up that same id in RevenueCat, so drift here breaks verification.
//

import Foundation
import RevenueCat
import YentlShared

/// Outcome of a date-fee purchase attempt, for the pay-gate UI.
enum DateFeePurchaseOutcome {
    /// Purchase completed AND the backend verified + recorded it.
    /// `matchPaid` is true when the other participant had already paid —
    /// the chat unlocks right now.
    case recorded(matchPaid: Bool)
    /// The user backed out of the store sheet. Not an error.
    case cancelled
    /// The purchase is pending external approval (e.g. Ask to Buy).
    case pending
    /// The store purchase SUCCEEDED but record-payment failed (offline,
    /// or the backend's RevenueCat secret isn't configured yet). The
    /// purchase is safe: recordPayment is idempotent on the transaction id,
    /// so retrying verification with `transactionID` never charges again.
    case purchasedButNotRecorded(message: String, transactionID: String?)
    /// The purchase itself failed.
    case failed(String)
}

/// Thin, stateless wrapper around the RevenueCat SDK singleton.
@MainActor
enum PurchaseService {
    /// The offering that carries the date fee (RevenueCat dashboard).
    static let dateFeeOfferingID = "default"

    /// One-time SDK setup — call from the app's init, before any other use.
    /// Starts anonymous; `logIn` attaches the Supabase identity on sign-in.
    static func configure() {
        #if DEBUG
        Purchases.logLevel = .debug
        #endif
        Purchases.configure(withAPIKey: AppEnvironment.current.revenueCatAPIKey)
    }

    /// Attaches the signed-in Supabase user to RevenueCat (lowercased id,
    /// mirroring OneSignal/Stream). Best-effort: a failure only delays
    /// identity attach — purchase verification would then fail cleanly and
    /// recover on retry, so this never throws into the auth flow.
    static func logIn(supabaseUserID: String) async {
        do {
            _ = try await Purchases.shared.logIn(supabaseUserID.lowercased())
        } catch {
            print("PurchaseService: logIn failed: \(error)")
        }
    }

    /// Detaches the user on sign-out (back to an anonymous RevenueCat id).
    static func logOut() async {
        do {
            _ = try await Purchases.shared.logOut()
        } catch {
            // Benign when already anonymous (e.g. sign-out before any logIn).
            print("PurchaseService: logOut failed: \(error)")
        }
    }

    /// The purchasable date-fee package from the `default` offering.
    static func dateFeePackage() async throws -> Package {
        let offerings = try await Purchases.shared.offerings()
        guard let offering = offerings.offering(identifier: dateFeeOfferingID)
                ?? offerings.current,
              let package = offering.availablePackages.first else {
            throw PaymentError.server(
                status: 404,
                message: "Match unlock isn't available right now. Please try again later."
            )
        }
        return package
    }

    /// Localized display price of a package ("$4.99").
    static func localizedPrice(of package: Package) -> String {
        package.storeProduct.localizedPriceString
    }

    /// Buys the date fee for a match and reports it to record-payment.
    /// Never throws — every path collapses into a `DateFeePurchaseOutcome`
    /// the pay gate renders, so a store/network failure can't corrupt the
    /// match or chat state.
    static func purchaseDateFee(package: Package, matchID: UUID) async -> DateFeePurchaseOutcome {
        let result: PurchaseResultData
        do {
            result = try await Purchases.shared.purchase(package: package)
        } catch ErrorCode.purchaseCancelledError {
            return .cancelled
        } catch ErrorCode.paymentPendingError {
            return .pending
        } catch {
            return .failed(error.localizedDescription)
        }
        if result.userCancelled { return .cancelled }
        guard let transactionID = result.transaction?.transactionIdentifier else {
            // Should not happen for a completed consumable purchase; surface
            // it as recorded-later rather than pretending it failed.
            return .purchasedButNotRecorded(
                message: "The purchase completed but couldn't be verified yet.",
                transactionID: nil
            )
        }
        do {
            let response = try await PaymentService.shared.recordPayment(
                matchID: matchID, storeTransactionID: transactionID
            )
            return .recorded(matchPaid: response.matchPaid)
        } catch {
            return .purchasedButNotRecorded(
                message: error.localizedDescription,
                transactionID: transactionID
            )
        }
    }
}
