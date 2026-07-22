import Foundation
import Observation
import Supabase

/// Chat-channel errors surfaced to the UI.
public enum StreamChannelError: LocalizedError {
    case unexpected(any Error)

    public var errorDescription: String? {
        switch self {
        case .unexpected(let error):
            return error.localizedDescription
        }
    }
}

/// The `stream-channel` Edge Function's confirmation that a match's Stream
/// channel exists (created now or already there — the function is idempotent).
public struct StreamChannelResponse: Decodable, Sendable, Equatable {
    /// Channel id within its type, `match-<match UUID, lowercased>`.
    public let channelID: String
    /// Always `messaging` today.
    public let channelType: String
    /// Full Stream cid, `messaging:match-<uuid>`.
    public let cid: String

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case channelType = "channel_type"
        case cid
    }
}

/// Ensures the Stream channel for a confirmed match exists, via the
/// `stream-channel` Edge Function (Phase 7 Slice 3).
///
/// Channel *creation* is server-side because only the server (holding the
/// Stream API secret) can upsert the Stream users first — a matched partner
/// who has never opened chat does not exist in Stream, so a client-created
/// channel could not reliably include them. The function verifies the caller
/// is a participant and the match is `confirmed`; it is idempotent, so
/// calling it again for the same match is safe and cheap.
@MainActor
@Observable
public final class StreamChannelService {
    public static let shared = StreamChannelService()

    private init() {}

    /// Match ids whose channel this session has already ensured — skips the
    /// network round-trip on repeat opens. Only successful calls are cached,
    /// and the server call is idempotent, so this is purely an optimization.
    private var ensured: Set<UUID> = []

    /// Ensures the `messaging:match-<id>` channel exists with both
    /// participants as members. Call on observing a confirmed match and/or
    /// right before opening its conversation.
    @discardableResult
    public func ensureMatchChannel(matchID: UUID) async throws -> StreamChannelResponse {
        if ensured.contains(matchID) {
            return StreamChannelResponse(matchID: matchID)
        }
        do {
            let response: StreamChannelResponse = try await Backend.supabase.functions
                .invoke(
                    "stream-channel",
                    options: FunctionInvokeOptions(body: ["match_id": matchID.uuidString.lowercased()])
                )
            ensured.insert(matchID)
            return response
        } catch {
            if error is CancellationError { throw error }
            throw StreamChannelError.unexpected(error)
        }
    }

    /// Forgets the ensured-channel cache — call on sign-out / account switch.
    public func reset() {
        ensured.removeAll()
    }
}

extension StreamChannelResponse {
    /// The response the server would give for `matchID` — used when the
    /// session-local cache already knows the channel exists.
    fileprivate init(matchID: UUID) {
        let id = "match-\(matchID.uuidString.lowercased())"
        // Synthesized memberwise init (same-file access).
        self.init(channelID: id, channelType: "messaging", cid: "messaging:\(id)")
    }
}
