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
    /// Dev uses a RevenueCat **Test Store** app (`test_…` key): purchases
    /// complete in the simulator with no App Store Connect setup. Prod will
    /// swap to the real App Store app's `appl_…` key.
    public var revenueCatAPIKey: String {
        switch self {
        case .dev:
            return "test_XOkuIQYwjTJJWLMJkFlUWTXInKa"
        case .staging:
            fatalError("staging RevenueCat app not yet configured")
        case .prod:
            fatalError("prod RevenueCat app not yet configured")
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
