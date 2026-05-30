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
            supabaseKey: env.supabasePublishableKey
        )
    }()
}
