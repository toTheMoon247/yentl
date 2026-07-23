import Foundation

/// Moderation state of an account — mirrors `users.account_status`
/// (Phase 11: active / suspended / banned).
public enum AccountStatusKind: String, Codable, Sendable {
    case active
    case suspended
    case banned
}

/// The owner-readable moderation slice of a `public.users` row
/// (`account_status`, `suspended_until`, `moderation_reason` — RLS lets a
/// user select their own row). Input for the consumer account-blocked gate
/// and shown on the matchmaker report detail.
public struct AccountStatus: Codable, Sendable, Equatable {
    public let kind: AccountStatusKind
    public let suspendedUntil: Date?
    /// Matchmaker-entered reason for the current suspension/ban; nil when
    /// active.
    public let moderationReason: String?

    public init(kind: AccountStatusKind, suspendedUntil: Date? = nil, moderationReason: String? = nil) {
        self.kind = kind
        self.suspendedUntil = suspendedUntil
        self.moderationReason = moderationReason
    }

    /// Mirrors the SQL `account_is_blocked` helper: banned is always blocked;
    /// suspended only while `suspendedUntil` is still in the future. A lapsed
    /// suspension is NOT blocked.
    public func isBlocked(at now: Date = Date()) -> Bool {
        switch kind {
        case .banned:
            return true
        case .suspended:
            guard let suspendedUntil else { return false }
            return suspendedUntil > now
        case .active:
            return false
        }
    }

    public var isBlocked: Bool { isBlocked(at: Date()) }

    enum CodingKeys: String, CodingKey {
        case kind = "account_status"
        case suspendedUntil = "suspended_until"
        case moderationReason = "moderation_reason"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown future status degrades to .active (no gate) rather than
        // a decoding error — an app update must never lock users out, same
        // convention as ProfileService's review-state read.
        let raw = try container.decode(String.self, forKey: .kind)
        kind = AccountStatusKind(rawValue: raw) ?? .active
        moderationReason = try container.decodeIfPresent(String.self, forKey: .moderationReason)
        // PostgREST serialises timestamptz as ISO8601 with a UTC offset and
        // (usually) fractional seconds; parse both shapes.
        if let stamp = try container.decodeIfPresent(String.self, forKey: .suspendedUntil) {
            suspendedUntil = Self.parseTimestamp(stamp)
        } else {
            suspendedUntil = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encodeIfPresent(moderationReason, forKey: .moderationReason)
        if let suspendedUntil {
            try container.encode(
                Self.timestampFormatter.string(from: suspendedUntil), forKey: .suspendedUntil
            )
        }
    }

    /// "2026-07-30T12:00:00+00:00" / "…12:00:00.123456+00:00" / "…Z" → Date.
    static func parseTimestamp(_ string: String) -> Date? {
        if let date = timestampFormatter.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// One row of the matchmaker Reports queue (returned by the staff-only
/// `moderation_open_reports` RPC): an OPEN report enriched with both parties'
/// display names, the reported user's current account status, and how many
/// reports (any status) exist against them.
public struct ModerationReport: Codable, Sendable, Identifiable, Hashable {
    public let reportID: UUID
    /// Raw `reports.reason` token — render via `reasonLabel`.
    public let reason: String
    public let note: String?
    /// When the report was filed, as epoch seconds (same convention as
    /// `MatchHistoryEntry` / `PendingReviewProfile`).
    public let createdAtEpoch: Double
    /// The match the report came from, when it was filed in a chat.
    public let matchID: UUID?
    public let reporterID: UUID
    /// Nil when the reporter has no profile row.
    public let reporterDisplayName: String?
    public let reportedID: UUID
    /// Nil when the reported user has no profile row.
    public let reportedDisplayName: String?
    /// Raw `users.account_status` of the reported user — render via
    /// `reportedStatusKind`.
    public let reportedAccountStatus: String
    /// Count of ALL reports (any status) against the reported user — the
    /// repeat-offender signal shown as "N reports".
    public let reportsAgainstReported: Int

    public var id: UUID { reportID }
    public var createdAt: Date { Date(timeIntervalSince1970: createdAtEpoch) }

    /// The canned reason, when the raw token is a known `ReportReason`.
    public var reasonKind: ReportReason? { ReportReason(rawValue: reason) }
    /// Human-readable reason for lists/details; falls back to the raw token
    /// for a future reason this build doesn't know.
    public var reasonLabel: String { reasonKind?.label ?? reason }
    /// The reported user's status, when this build knows the value.
    public var reportedStatusKind: AccountStatusKind? {
        AccountStatusKind(rawValue: reportedAccountStatus)
    }

    public init(
        reportID: UUID,
        reason: String,
        note: String? = nil,
        createdAtEpoch: Double,
        matchID: UUID? = nil,
        reporterID: UUID,
        reporterDisplayName: String? = nil,
        reportedID: UUID,
        reportedDisplayName: String? = nil,
        reportedAccountStatus: String = "active",
        reportsAgainstReported: Int = 1
    ) {
        self.reportID = reportID
        self.reason = reason
        self.note = note
        self.createdAtEpoch = createdAtEpoch
        self.matchID = matchID
        self.reporterID = reporterID
        self.reporterDisplayName = reporterDisplayName
        self.reportedID = reportedID
        self.reportedDisplayName = reportedDisplayName
        self.reportedAccountStatus = reportedAccountStatus
        self.reportsAgainstReported = reportsAgainstReported
    }

    enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
        case reason
        case note
        case createdAtEpoch = "created_at_epoch"
        case matchID = "match_id"
        case reporterID = "reporter_id"
        case reporterDisplayName = "reporter_display_name"
        case reportedID = "reported_id"
        case reportedDisplayName = "reported_display_name"
        case reportedAccountStatus = "reported_account_status"
        case reportsAgainstReported = "reports_against_reported"
    }
}

/// Suspension lengths offered in the matchmaker Suspend sheet.
public enum SuspensionDuration: String, CaseIterable, Sendable, Identifiable {
    case day = "24 hours"
    case week = "7 days"
    case month = "30 days"

    public var id: String { rawValue }

    /// The `until` timestamp this duration produces, from `now`.
    public func until(from now: Date = Date()) -> Date {
        switch self {
        case .day: return now.addingTimeInterval(24 * 3600)
        case .week: return now.addingTimeInterval(7 * 24 * 3600)
        case .month: return now.addingTimeInterval(30 * 24 * 3600)
        }
    }
}
