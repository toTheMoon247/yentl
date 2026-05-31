import Foundation
import Supabase

/// Shared backend clients for both apps.
///
/// `Backend.supabase` is the single configured `SupabaseClient` instance.
/// Initialized lazily on first access using values from
/// `AppEnvironment.current`.
public enum Backend {
    public static let supabase: SupabaseClient = {
        let env = AppEnvironment.current
        return SupabaseClient(
            supabaseURL: env.supabaseURL,
            supabaseKey: env.supabasePublishableKey,
            options: SupabaseClientOptions(
                // Session persistence is intentional, not incidental: store the
                // session in the Keychain so it survives cold launches, and keep
                // the access token auto-refreshed. These match the SDK defaults
                // today, but we pin them explicitly so a future SDK default change
                // can't silently sign every user out on upgrade.
                auth: SupabaseClientOptions.AuthOptions(
                    storage: AuthClient.Configuration.defaultLocalStorage,
                    autoRefreshToken: true,
                    // Emit the stored session immediately on launch instead of
                    // waiting for a network refresh first — faster signed-in
                    // restoration, and it works offline. (Becomes the SDK default
                    // in the next major version.)
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }()
}
