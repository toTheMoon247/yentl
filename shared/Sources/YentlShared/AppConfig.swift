import Foundation

/// Build-configurable app constants. Values that differ between development and
/// production live here and are switched by build configuration, so a release
/// build can't accidentally ship a development value — there's nothing to
/// remember to change.
public enum AppConfig {
    /// How long a pending match lasts before it auto-expires ("ignored =
    /// rejected"). Debug builds use a short window so the expiry flow can be
    /// tested without waiting a full day; release builds are always 24 hours.
    ///
    /// Passed to `create_match`; the server clamps it to a sane range and
    /// defaults to 24h, so this is the single source of truth for the window.
    public static var matchExpirySeconds: Int {
        #if DEBUG
        return 5 * 60          // 5 minutes — fast enough to test expiry
        #else
        return 24 * 60 * 60    // 24 hours
        #endif
    }
}
