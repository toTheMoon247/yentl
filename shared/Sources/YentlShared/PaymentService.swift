import Foundation
import Observation
import Supabase

/// Payment errors surfaced to the UI (Phase 9).
public enum PaymentError: LocalizedError {
    /// The `record-payment` Edge Function rejected the call — carries its
    /// HTTP status and the server's `error` message so the UI can distinguish
    /// "no matching purchase found" (402) from "server misconfigured" (500).
    case server(status: Int, message: String)
    case unexpected(any Error)

    public var errorDescription: String? {
        switch self {
        case .server(_, let message):
            return message
        case .unexpected(let error):
            return error.localizedDescription
        }
    }
}

/// The subset of a `payments` ledger row the backend returns to clients
/// (see record-payment's `publicRow` — never the RevenueCat internals).
public struct PaymentRecord: Decodable, Sendable, Equatable {
    public let id: UUID
    public let matchID: UUID
    public let userID: UUID
    public let productID: String?
    public let storeTransactionID: String
    /// `paid` or `refunded` (the table's CHECK constraint).
    public let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case matchID = "match_id"
        case userID = "user_id"
        case productID = "product_id"
        case storeTransactionID = "store_transaction_id"
        case status
    }
}

/// Success payload of the `record-payment` Edge Function.
public struct RecordPaymentResponse: Decodable, Sendable {
    /// The (possibly pre-existing — the call is idempotent) ledger row.
    public let payment: PaymentRecord
    /// True iff BOTH participants have now paid — the chat-unlock predicate,
    /// evaluated server-side in the same call so the UI can react immediately.
    public let matchPaid: Bool

    enum CodingKeys: String, CodingKey {
        case payment
        case matchPaid = "match_paid"
    }
}

/// Phase 9: the consumer side of the per-confirmed-date fee ledger.
///
/// The ledger itself is written ONLY server-side (`record-payment` /
/// `revenuecat-webhook`, after RevenueCat verification) — this service just
/// reads payment state and reports a completed store purchase for
/// verification. The actual StoreKit purchase lives in the consumer app's
/// PurchaseService (the RevenueCat SDK is linked into the app, not this
/// package, so the matchmaker app never carries it).
@MainActor
@Observable
public final class PaymentService {
    public static let shared = PaymentService()

    private init() {}

    /// True iff BOTH participants of the match have paid — the chat gate.
    /// (SECURITY DEFINER RPC: a participant can evaluate it without being
    /// able to see the other participant's payment row.)
    public func isMatchPaid(matchID: UUID) async throws -> Bool {
        do {
            return try await Backend.supabase
                .rpc("is_match_paid", params: IsPaidParams(match: matchID))
                .execute()
                .value
        } catch {
            if error is CancellationError { throw error }
            throw PaymentError.unexpected(error)
        }
    }

    /// Whether the CURRENT user has a `paid` row for this match — drives the
    /// "you've confirmed, waiting for them" state. RLS already limits reads
    /// to the caller's own rows; the explicit `user_id` filter keeps the
    /// answer correct for staff accounts too (whose RLS can see all rows).
    public func hasCurrentUserPaid(matchID: UUID) async throws -> Bool {
        do {
            let userID = try await Backend.supabase.auth.session.user.id
            let rows: [RowID] = try await Backend.supabase
                .from("payments")
                .select("id")
                .eq("match_id", value: matchID)
                .eq("user_id", value: userID)
                .eq("status", value: "paid")
                .limit(1)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
            if error is CancellationError { throw error }
            throw PaymentError.unexpected(error)
        }
    }

    /// Reports a completed store purchase to the `record-payment` Edge
    /// Function, which re-verifies it against RevenueCat (never trusting
    /// this client) and writes the `paid` ledger row. Idempotent on
    /// `storeTransactionID` — retrying after a network failure is safe.
    @discardableResult
    public func recordPayment(
        matchID: UUID, storeTransactionID: String
    ) async throws -> RecordPaymentResponse {
        do {
            return try await Backend.supabase.functions.invoke(
                "record-payment",
                options: FunctionInvokeOptions(body: RecordParams(
                    matchID: matchID.uuidString.lowercased(),
                    storeTransactionID: storeTransactionID
                ))
            )
        } catch let error as FunctionsError {
            if case .httpError(let code, let data) = error {
                throw PaymentError.server(
                    status: code, message: Self.serverMessage(from: data, status: code)
                )
            }
            throw PaymentError.unexpected(error)
        } catch {
            if error is CancellationError { throw error }
            throw PaymentError.unexpected(error)
        }
    }

    /// Extracts the `error` field of a record-payment failure body; falls
    /// back to a generic status-code message when the body isn't parseable.
    nonisolated static func serverMessage(from data: Data, status: Int) -> String {
        struct Body: Decodable { let error: String? }
        if let message = (try? JSONDecoder().decode(Body.self, from: data))?.error,
           !message.isEmpty {
            return message
        }
        return "Payment could not be recorded (HTTP \(status))."
    }

    // Internal (not private) so the key-drift unit tests can see them — a
    // drifted key would 400 server-side (RecordParams) or break the RPC call.
    struct IsPaidParams: Encodable {
        let match: UUID
    }

    struct RecordParams: Encodable {
        let matchID: String
        let storeTransactionID: String
        enum CodingKeys: String, CodingKey {
            case matchID = "match_id"
            case storeTransactionID = "store_transaction_id"
        }
    }

    private struct RowID: Decodable {
        let id: UUID
    }
}
