import Foundation
import Observation
import Supabase

/// Match-related errors surfaced to the UI.
public enum MatchError: LocalizedError {
    case unexpected(any Error)

    public var errorDescription: String? {
        switch self {
        case .unexpected(let error):
            return error.localizedDescription
        }
    }
}

/// Match creation (matchmaker) and the consumer's match list + responses.
@MainActor
@Observable
public final class MatchService {
    public static let shared = MatchService()

    private init() {}

    /// Creates a pending match between two users (matchmaker). Returns the id.
    @discardableResult
    public func createMatch(_ userOne: UUID, _ userTwo: UUID) async throws -> UUID {
        do {
            return try await Backend.supabase
                .rpc("create_match", params: CreateParams(userOne: userOne, userTwo: userTwo))
                .execute()
                .value
        } catch {
            if error is CancellationError { throw error }
            throw MatchError.unexpected(error)
        }
    }

    /// The current user's matches (with the other person's public profile).
    public func myMatches() async throws -> [MatchSummary] {
        do {
            return try await Backend.supabase
                .rpc("my_matches")
                .execute()
                .value
        } catch {
            if error is CancellationError { throw error }
            throw MatchError.unexpected(error)
        }
    }

    /// Accept or reject a pending match the current user is part of.
    public func respond(matchID: UUID, accept: Bool) async throws {
        do {
            try await Backend.supabase
                .rpc("respond_to_match", params: RespondParams(match: matchID, accept: accept))
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw MatchError.unexpected(error)
        }
    }

    private struct CreateParams: Encodable {
        let userOne: UUID
        let userTwo: UUID
        enum CodingKeys: String, CodingKey {
            case userOne = "user_one"
            case userTwo = "user_two"
        }
    }

    private struct RespondParams: Encodable {
        let match: UUID
        let accept: Bool
    }
}
