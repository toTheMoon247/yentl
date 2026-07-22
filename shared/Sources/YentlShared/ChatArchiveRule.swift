import Foundation

/// Phase 7 (Slice 3): the 48h-inactivity archive rule for chats.
///
/// A conversation is *archived* — hidden in a secondary "Archived" inbox
/// section, not closed — once 48 hours pass with no message. The clock runs
/// from the last message, or from channel creation for a chat where nobody
/// has written yet (so a never-messaged match archives on the same rule).
///
/// This is pure view-state derived on read: nothing is stored, no Stream
/// channel is frozen, and either person sending a message naturally
/// restores the chat to the active list because `last_message_at` moves.
public enum ChatArchiveRule {
    /// 48 hours, decided 2026-07-22 (docs/implementation-plan.md, Phase 7).
    public static let inactivityWindow: TimeInterval = 48 * 60 * 60

    /// Whether a chat with the given activity timestamps is archived at `now`.
    /// - Parameters:
    ///   - lastMessageAt: when the latest message was sent, if any.
    ///   - createdAt: when the channel was created — the fallback clock start.
    public static func isArchived(
        lastMessageAt: Date?,
        createdAt: Date,
        now: Date = Date()
    ) -> Bool {
        let lastActivity = lastMessageAt ?? createdAt
        return now.timeIntervalSince(lastActivity) >= inactivityWindow
    }
}
