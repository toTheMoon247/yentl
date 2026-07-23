import Foundation
import Observation
import Supabase

/// Moderation errors surfaced to the UI.
public enum ModerationError: LocalizedError {
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

/// Phase 11 moderation: the matchmaker Reports queue + suspend/ban/reinstate
/// (staff-only security-definer RPCs), and the consumer's read of their own
/// account status for the blocked-account gate.
///
/// Mirrors `MatchmakerService` — all Supabase access stays in the package;
/// hosts inject it as `@Environment(ModerationService.self)`.
@MainActor
@Observable
public final class ModerationService {
    public static let shared = ModerationService()

    private init() {}

    // MARK: - Staff: the Reports queue

    /// Count behind the Reports tab badge. Kept fresh by `openReports()` /
    /// `refreshOpenReportCount()`; 0 hides the badge.
    public private(set) var openReportCount = 0

    /// Open reports, newest first, enriched for the Reports tab.
    public func openReports() async throws -> [ModerationReport] {
        do {
            let rows: [ModerationReport] = try await Backend.supabase
                .rpc("moderation_open_reports")
                .execute()
                .value
            openReportCount = rows.count
            return rows
        } catch {
            if error is CancellationError { throw error }
            throw ModerationError.unexpected(error)
        }
    }

    /// Badge-only refresh (e.g. on tab-bar appearance). Swallows errors — a
    /// failed badge poll must never surface UI errors outside the tab.
    public func refreshOpenReportCount() async {
        _ = try? await openReports()
    }

    /// Close a report without touching the account: `dismiss` marks it
    /// dismissed (nothing wrong), otherwise reviewed.
    public func resolveReport(id: UUID, dismiss: Bool) async throws {
        do {
            try await Backend.supabase
                .rpc("resolve_report", params: ResolveParams(reportId: id, dismiss: dismiss))
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw ModerationError.unexpected(error)
        }
    }

    /// Suspend `target` until `until` (must be in the future). A linked
    /// report is marked actioned.
    public func suspend(
        target: UUID, until: Date, reason: String, reportId: UUID? = nil
    ) async throws {
        do {
            try await Backend.supabase
                .rpc("suspend_user", params: SuspendParams(
                    target: target,
                    until: AccountStatus.timestampFormatter.string(from: until),
                    reason: reason,
                    reportId: reportId
                ))
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw ModerationError.unexpected(error)
        }
    }

    /// Ban `target` (permanent until reinstated). A linked report is marked
    /// actioned.
    public func ban(target: UUID, reason: String, reportId: UUID? = nil) async throws {
        do {
            try await Backend.supabase
                .rpc("ban_user", params: BanParams(
                    target: target, reason: reason, reportId: reportId
                ))
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw ModerationError.unexpected(error)
        }
    }

    /// Lift a suspension/ban — the account returns to active.
    public func reinstate(target: UUID) async throws {
        do {
            try await Backend.supabase
                .rpc("reinstate_user", params: TargetParam(target: target))
                .execute()
        } catch {
            if error is CancellationError { throw error }
            throw ModerationError.unexpected(error)
        }
    }

    /// A user's current moderation status (staff RLS reads anyone's row) —
    /// used by the report detail so its actions reflect the live status, not
    /// the snapshot taken when the queue was listed.
    public func fetchAccountStatus(of userID: UUID) async throws -> AccountStatus? {
        do {
            let rows: [AccountStatus] = try await Backend.supabase
                .from("users")
                .select("account_status, suspended_until, moderation_reason")
                .eq("id", value: userID)
                .limit(1)
                .execute()
                .value
            return rows.first
        } catch {
            if error is CancellationError { throw error }
            throw ModerationError.unexpected(error)
        }
    }

    // MARK: - Consumer: the account-blocked gate

    /// The signed-in user's own account status (own-row RLS), or nil when the
    /// users row is missing. `isBlocked` drives the consumer gate.
    public func fetchMyAccountStatus() async throws -> AccountStatus? {
        let userID: UUID
        do {
            userID = try await Backend.supabase.auth.session.user.id
        } catch {
            throw ModerationError.notSignedIn
        }
        return try await fetchAccountStatus(of: userID)
    }

}

// MARK: - RPC params
//
// File-scoped (not nested in ModerationService) so their `CodingKeys` don't
// trip SwiftLint's type-nesting rule — same convention as AuthService's row
// structs. Internal (not private) so the snake_case keys are unit-tested: a
// drifted key would silently drop the RPC argument.

private struct TargetParam: Encodable { let target: UUID }

struct ResolveParams: Encodable {
    let reportId: UUID
    let dismiss: Bool

    enum CodingKeys: String, CodingKey {
        case reportId = "report_id"
        case dismiss
    }
}

/// `until` travels as an ISO8601 string (Postgres casts it to timestamptz).
struct SuspendParams: Encodable {
    let target: UUID
    let until: String
    let reason: String
    let reportId: UUID?

    enum CodingKeys: String, CodingKey {
        case target
        case until
        case reason
        case reportId = "report_id"
    }
}

struct BanParams: Encodable {
    let target: UUID
    let reason: String
    let reportId: UUID?

    enum CodingKeys: String, CodingKey {
        case target
        case reason
        case reportId = "report_id"
    }
}
