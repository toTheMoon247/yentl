import Foundation

/// A discovery swipe action. Mirrors the `public.swipe_action` Postgres enum.
/// A "like" is one-directional interest only — matches are created by
/// matchmakers, never by mutual likes.
public enum SwipeAction: String, Codable, Sendable {
    case like
    case pass
}
