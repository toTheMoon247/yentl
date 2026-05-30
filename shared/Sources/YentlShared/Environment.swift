import Foundation

/// Build-time environment for the apps.
///
/// Reads the `YENTL_ENV` value from the host bundle's `Info.plist`
/// (populated via xcconfig once those are wired up). Defaults to
/// `.dev` when unset so local development has no extra friction.
///
/// Concrete environment-specific values (Supabase URLs, anon keys, etc.)
/// land here once Phase 1 starts wiring the backend.
public enum AppEnvironment: String {
    case dev
    case staging
    case prod

    /// The environment the running app was built for.
    public static var current: AppEnvironment {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "YENTL_ENV") as? String,
              let env = AppEnvironment(rawValue: raw) else {
            return .dev
        }
        return env
    }
}
