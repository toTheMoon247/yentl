import Foundation

/// Mirror of the `public.user_role` enum in the database.
///
/// Stays in sync with `supabase/migrations/20260530202003_users_table_and_rls.sql`.
public enum UserRole: String, Codable, CaseIterable, Sendable {
    case user
    case matchmaker
    case admin

    /// Convenience: whether this role has access to the Yentl Matchmaker app.
    public var isStaff: Bool {
        switch self {
        case .matchmaker, .admin: return true
        case .user:               return false
        }
    }
}
