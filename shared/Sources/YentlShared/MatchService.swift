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

/// Lifecycle push events the `notify` Edge Function accepts. Raw values must
/// match the function's `EVENTS` keys (supabase/functions/notify/index.ts).
public enum MatchPushEvent: String, Sendable {
    /// Matchmaker created a pending match — "You have a new match!".
    case created = "match_created"
    /// Both sides accepted — "It's a match!".
    case confirmed = "match_confirmed"
}

/// Match creation (matchmaker) and the consumer's match list + responses.
@MainActor
@Observable
public final class MatchService {
    public static let shared = MatchService()

    private init() {}

    /// Creates a pending match between two users (matchmaker). Returns the id.
    /// `expiresInSeconds` defaults to the build's configured window (short in
    /// Debug so expiry is testable, 24h in release).
    @discardableResult
    public func createMatch(
        _ userOne: UUID,
        _ userTwo: UUID,
        expiresInSeconds: Int = AppConfig.matchExpirySeconds
    ) async throws -> UUID {
        do {
            return try await Backend.supabase
                .rpc("create_match", params: CreateParams(
                    userOne: userOne, userTwo: userTwo, expiresInSeconds: expiresInSeconds
                ))
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

    /// Blocks the other participant of a match: the match moves to the
    /// terminal `blocked` state for BOTH people (each side's next refresh no
    /// longer contains it), a block row is recorded for matchmakers, and an
    /// optional report is filed in the same gesture. Safe to call twice.
    public func blockMatch(
        matchID: UUID, reason: ReportReason? = nil, note: String? = nil
    ) async throws {
        do {
            try await Backend.supabase
                .rpc("block_match", params: BlockParams(
                    match: matchID, reason: reason?.rawValue, note: Self.normalized(note)
                ))
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw MatchError.unexpected(error)
        }
    }

    /// Files a report about a user, optionally tied to a match the caller is
    /// part of. The server enforces the canned-reason list and participant
    /// checks. Blocking is separate — see `blockMatch`.
    public func reportUser(
        userID: UUID, reason: ReportReason, matchID: UUID? = nil, note: String? = nil
    ) async throws {
        do {
            try await Backend.supabase
                .rpc("report_user", params: ReportParams(
                    reported: userID, reason: reason.rawValue,
                    match: matchID, note: Self.normalized(note)
                ))
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw MatchError.unexpected(error)
        }
    }

    /// Asks the `notify` Edge Function to push a lifecycle notification for a
    /// match to BOTH participants (Phase 8). Best-effort BY DESIGN: this never
    /// throws — a missed push must never block or fail the match action that
    /// triggered it, so call sites just `Task { await ... }` and move on.
    ///
    /// The server re-checks everything that matters (caller is a participant
    /// or staff, and the match is actually in the state the event claims), so
    /// firing `.confirmed` after every accept is safe: the accept that merely
    /// leaves the match pending gets a 409 and no push is sent.
    public func sendMatchPush(matchID: UUID, event: MatchPushEvent) async {
        do {
            try await Backend.supabase.functions.invoke(
                "notify",
                options: FunctionInvokeOptions(body: NotifyParams(
                    matchID: matchID, event: event.rawValue
                ))
            )
        } catch is CancellationError {
        } catch {
            // Log-only: fire-and-forget by contract (see above).
            print("MatchService: \(event.rawValue) push for \(matchID) failed: \(error)")
        }
    }

    /// Trims a free-text note; empty becomes nil so the RPC's default (null)
    /// applies instead of storing an empty string.
    nonisolated static func normalized(_ note: String?) -> String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    struct CreateParams: Encodable {
        let userOne: UUID
        let userTwo: UUID
        let expiresInSeconds: Int
        enum CodingKeys: String, CodingKey {
            case userOne = "user_one"
            case userTwo = "user_two"
            case expiresInSeconds = "expires_in_seconds"
        }
    }

    private struct RespondParams: Encodable {
        let match: UUID
        let accept: Bool
    }

    // Internal (not private) so the key-drift unit tests can see them, like
    // CreateParams. Optionals rely on synthesized encodeIfPresent: a nil key
    // is omitted entirely, so the RPC's SQL default (null) applies.
    struct BlockParams: Encodable {
        let match: UUID
        let reason: String?
        let note: String?
    }

    struct ReportParams: Encodable {
        let reported: UUID
        let reason: String
        let match: UUID?
        let note: String?
    }

    /// Body for the `notify` Edge Function. Internal so the key-drift unit
    /// test can see it: a drifted key would 400 server-side and every push
    /// would silently vanish (the call is fire-and-forget).
    struct NotifyParams: Encodable {
        let matchID: UUID
        let event: String
        enum CodingKeys: String, CodingKey {
            case matchID = "match_id"
            case event
        }
    }
}
