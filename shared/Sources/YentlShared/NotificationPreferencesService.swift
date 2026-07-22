import Foundation
import Observation
import Supabase

/// The signed-in user's two push toggles (Phase 8 Slice 3).
///
/// Opt-out model: the `notification_preferences` row is created lazily, the
/// first time a toggle is touched — so **no row means both ON**, and
/// `.defaults` is the value every reader must assume when nothing is stored.
public struct NotificationPreferences: Equatable, Sendable {
    /// OneSignal match-lifecycle pushes ("You have a new match!" etc.).
    /// Enforced server-side by the `notify` Edge Function.
    public var matchPushes: Bool
    /// Stream chat-message pushes. Enforced client-side: the app registers or
    /// removes its Stream push device to match (see the consumer ChatService).
    public var messagePushes: Bool

    public static let defaults = NotificationPreferences(matchPushes: true, messagePushes: true)

    public init(matchPushes: Bool, messagePushes: Bool) {
        self.matchPushes = matchPushes
        self.messagePushes = messagePushes
    }
}

/// Notification-preference errors surfaced to the UI.
public enum NotificationPreferencesError: LocalizedError {
    case notSignedIn
    case unexpected(any Error)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .unexpected(let error):
            return error.localizedDescription
        }
    }
}

/// Reads and writes the signed-in user's row in
/// `public.notification_preferences` — plain table access under RLS (own row
/// only), in the ProfileService idiom. No RPC: a preference row has no side
/// effects that need a security-definer function to keep in sync.
@MainActor
@Observable
public final class NotificationPreferencesService {
    public static let shared = NotificationPreferencesService()

    private init() {}

    /// Last value fetched or written this session, nil before the first
    /// fetch. Per-user — the host app must call `reset()` when the signed-in
    /// identity changes (the same discipline as StreamChannelService).
    public private(set) var cached: NotificationPreferences?

    /// Clears the per-user cache on sign-out / account switch.
    public func reset() {
        cached = nil
    }

    /// The signed-in user's preferences; `.defaults` (both ON) when no row
    /// has ever been written.
    public func fetch() async throws -> NotificationPreferences {
        let userID = try await currentUserID()
        do {
            // Array + limit(1) rather than .single() so a missing row means
            // "defaults", not an error (rows are created lazily).
            let rows: [Row] = try await Backend.supabase
                .from("notification_preferences")
                .select("match_pushes, message_pushes")
                .eq("user_id", value: userID)
                .limit(1)
                .execute()
                .value
            let prefs = rows.first.map {
                NotificationPreferences(matchPushes: $0.matchPushes, messagePushes: $0.messagePushes)
            } ?? .defaults
            cached = prefs
            return prefs
        } catch {
            if error is CancellationError { throw error }
            throw NotificationPreferencesError.unexpected(error)
        }
    }

    /// Persists the given preferences as the signed-in user's row (upsert:
    /// first write creates the row, later writes update it — RLS scopes both
    /// to the caller's own user_id).
    public func update(_ prefs: NotificationPreferences) async throws {
        let userID = try await currentUserID()
        do {
            try await Backend.supabase
                .from("notification_preferences")
                .upsert(
                    UpsertPayload(
                        userId: userID,
                        matchPushes: prefs.matchPushes,
                        messagePushes: prefs.messagePushes
                    ),
                    onConflict: "user_id"
                )
                .execute()
            cached = prefs
        } catch {
            if error is CancellationError { throw error }
            throw NotificationPreferencesError.unexpected(error)
        }
    }

    /// Best-effort read of the message-push toggle, for gating Stream device
    /// registration on connect. Never throws: the cached value if the session
    /// has one, else a fetch, else — on any failure — the default (ON). A
    /// stored OFF that can't be read may briefly re-register a device; the
    /// next successful settings visit reconciles it.
    public func messagePushesEnabled() async -> Bool {
        if let cached { return cached.messagePushes }
        return ((try? await fetch()) ?? .defaults).messagePushes
    }

    // MARK: - Private

    private func currentUserID() async throws -> UUID {
        do {
            return try await Backend.supabase.auth.session.user.id
        } catch {
            throw NotificationPreferencesError.notSignedIn
        }
    }

    private struct Row: Decodable {
        let matchPushes: Bool
        let messagePushes: Bool

        enum CodingKeys: String, CodingKey {
            case matchPushes = "match_pushes"
            case messagePushes = "message_pushes"
        }
    }

    // Internal (not private) so the key-drift unit tests can see it, like
    // MatchService.CreateParams: a drifted key would make every settings
    // write fail server-side.
    struct UpsertPayload: Encodable {
        let userId: UUID
        let matchPushes: Bool
        let messagePushes: Bool

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case matchPushes = "match_pushes"
            case messagePushes = "message_pushes"
        }
    }
}
