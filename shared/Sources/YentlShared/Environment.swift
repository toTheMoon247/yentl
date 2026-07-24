import Foundation

/// Build-time environment for the apps.
///
/// Reads the `YENTL_ENV` value from the host bundle's `Info.plist`
/// (populated via xcconfig once those are wired up). Defaults to
/// `.dev` when unset so local development has no extra friction.
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

    /// Supabase project URL for the current environment.
    ///
    /// Dev is hardcoded here for Phase 1 simplicity. Before staging/prod
    /// land — or before this repo goes public — these should move out to
    /// a gitignored `Supabase.plist` or xcconfig files.
    public var supabaseURL: URL {
        switch self {
        case .dev:
            return URL(string: "https://kegkaerpusgwgfjjrxha.supabase.co")!
        case .staging:
            fatalError("staging Supabase project not yet configured")
        case .prod:
            fatalError("prod Supabase project not yet configured")
        }
    }

    /// Supabase publishable key for the current environment.
    ///
    /// Publishable keys are intended to ship in the client by design —
    /// Row Level Security is what gates actual data access. Still, treat
    /// production keys as configuration that lives outside source control.
    public var supabasePublishableKey: String {
        switch self {
        case .dev:
            return "sb_publishable_Z5fAfXfKFdySFxkjw_czWg_PNzoBzaF"
        case .staging:
            fatalError("staging Supabase project not yet configured")
        case .prod:
            fatalError("prod Supabase project not yet configured")
        }
    }

    /// Stream Chat API key for the current environment.
    ///
    /// Like `supabasePublishableKey`, this is public by design: the API key
    /// only identifies the Stream app. Chat access is gated by per-user JWTs
    /// signed with the Stream API *secret*, which lives solely in the
    /// `stream-token` Edge Function's environment and never ships in the
    /// client or this repo.
    public var streamChatAPIKey: String {
        switch self {
        case .dev:
            return "63zc3wmbpa7v"
        case .staging:
            fatalError("staging Stream Chat app not yet configured")
        case .prod:
            fatalError("prod Stream Chat app not yet configured")
        }
    }

    /// RevenueCat public SDK key for the current environment (consumer app).
    ///
    /// Public by design, like `streamChatAPIKey` / `oneSignalAppID`: it only
    /// identifies the RevenueCat app to the client SDK. Purchase verification
    /// uses the RevenueCat *secret* key, which lives solely in the
    /// `record-payment` Edge Function's environment and never ships in the
    /// client or this repo.
    ///
    /// The app currently runs as `.dev` everywhere (`YENTL_ENV` is unset), and
    /// `.dev` points at the single live backend. Payments are the one thing that
    /// MUST differ by build type:
    ///   - **Debug** (simulator / local dev) → the RevenueCat **Test Store**
    ///     (`test_…`): purchases complete with no App Store Connect setup.
    ///   - **Release** (TestFlight / App Store archive) → the real **App Store**
    ///     app's `appl_…` key (RevenueCat project "Yentl", app `app59442a6809`,
    ///     product `match_unlock`) — so shipping builds do real purchases.
    /// The App Store app has its In-App Purchase key set in RevenueCat, so
    /// sandbox/live purchases verify.
    public var revenueCatAPIKey: String {
        switch self {
        case .dev:
            #if DEBUG
            return "test_XOkuIQYwjTJJWLMJkFlUWTXInKa"   // Test Store (simulator/dev)
            #else
            return "appl_ihJarJvOIqcqgCOIfnpFLMJevRK"   // App Store (TestFlight/release)
            #endif
        case .staging:
            fatalError("staging RevenueCat app not yet configured")
        case .prod:
            return "appl_ihJarJvOIqcqgCOIfnpFLMJevRK"
        }
    }

    /// OneSignal App ID for the current environment (consumer app).
    ///
    /// Like `streamChatAPIKey`, this is public by design: the App ID only
    /// identifies the OneSignal app in the client SDK. Sending notifications
    /// requires the OneSignal REST API key (and the APNs .p8), which live in
    /// OneSignal's dashboard / server-side and never ship in the client or
    /// this repo.
    public var oneSignalAppID: String {
        switch self {
        case .dev:
            return "d0a0569f-87cd-418b-801b-104795255ce2"
        case .staging:
            fatalError("staging OneSignal app not yet configured")
        case .prod:
            fatalError("prod OneSignal app not yet configured")
        }
    }
}
