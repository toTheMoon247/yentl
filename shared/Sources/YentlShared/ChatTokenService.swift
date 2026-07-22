import Foundation
import Observation
import Supabase

/// Chat-token errors surfaced to the UI.
public enum ChatTokenError: LocalizedError {
    case unexpected(any Error)

    public var errorDescription: String? {
        switch self {
        case .unexpected(let error):
            return error.localizedDescription
        }
    }
}

/// A Stream Chat user token issued by the `stream-token` Edge Function.
///
/// The function derives `user_id` from the caller's verified Supabase
/// session — the client cannot request a token for anyone else, so this
/// always describes the signed-in user.
public struct StreamTokenResponse: Decodable, Sendable, Equatable {
    /// The Stream user token (a JWT) to hand to the Stream SDK.
    public let token: String
    /// The Supabase user id the token was minted for (== Stream user id).
    public let userID: UUID
    /// Unix epoch seconds at which the token expires (1h from issue).
    public let expiresAtEpoch: Double

    enum CodingKeys: String, CodingKey {
        case token
        case userID = "user_id"
        case expiresAtEpoch = "expires_at"
    }

    /// `expiresAtEpoch` as a `Date`, for scheduling a refresh ahead of expiry.
    public var expiresAt: Date { Date(timeIntervalSince1970: expiresAtEpoch) }
}

/// Fetches Stream Chat user tokens for the signed-in user. Backs the Stream
/// SDK's token provider (Phase 7): called on connect and again whenever the
/// current token expires.
@MainActor
@Observable
public final class ChatTokenService {
    public static let shared = ChatTokenService()

    private init() {}

    /// Requests a fresh Stream user token from the `stream-token` Edge
    /// Function. The user's Supabase access token is attached automatically
    /// by the client; an unauthenticated call is rejected server-side (401).
    public func fetchStreamToken() async throws -> StreamTokenResponse {
        do {
            return try await Backend.supabase.functions
                .invoke("stream-token")
        } catch {
            if error is CancellationError { throw error }
            throw ChatTokenError.unexpected(error)
        }
    }
}
