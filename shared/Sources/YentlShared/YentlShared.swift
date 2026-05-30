import Foundation

/// Shared code consumed by both Yentl (the consumer app) and Yentl Matchmaker (the internal app).
///
/// Holds domain models, the Supabase API client, design tokens,
/// and any utilities that both apps need to agree on.
public enum YentlShared {
    /// Bumped manually as the shared API evolves. Useful for smoke-testing
    /// that both apps are linked against the same version.
    public static let version = "0.0.1"
}
