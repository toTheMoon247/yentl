import Foundation
import Observation
import Supabase

/// Authentication state derived from the Supabase session.
public enum AuthState: Sendable {
    /// Determining the initial state on launch.
    case loading
    /// No active session.
    case signedOut
    /// Active Supabase session.
    case signedIn(user: User)
}

/// Auth-related errors surfaced to the UI.
public enum AuthError: LocalizedError {
    /// Apple Sign-In is stubbed until the Apple Developer Program is active.
    /// See `docs/implementation-plan.md` Phase 8 — the enrolment is gated there.
    case appleSignInPendingDeveloperAccount
    case notSignedIn
    case unexpected(any Error)

    public var errorDescription: String? {
        switch self {
        case .appleSignInPendingDeveloperAccount:
            return "Sign in with Apple will be available once the Apple Developer account is active. Please sign in with Google for now."
        case .notSignedIn:
            return "You're not signed in."
        case .unexpected(let error):
            return error.localizedDescription
        }
    }
}

/// Wraps Supabase Auth for both apps.
///
/// Used from SwiftUI as `@Environment(AuthService.self)` (the host app
/// injects `AuthService.shared` into the environment).
@MainActor
@Observable
public final class AuthService {
    public private(set) var state: AuthState = .loading

    /// Convenience: the signed-in user's id as a String, or nil when signed out.
    /// Exposed so the host apps don't need to import the Supabase `Auth` submodule.
    public var currentUserIDString: String? {
        if case .signedIn(let user) = state { return user.id.uuidString }
        return nil
    }

    public static let shared = AuthService()

    private init() {
        Task { await observeAuthChanges() }
    }

    // MARK: - Sign in / out

    /// Sign in with Google via Supabase's OAuth flow.
    ///
    /// Uses `ASWebAuthenticationSession` under the hood, so the host app needs the
    /// matching custom URL scheme registered in its Info.plist and on Supabase's
    /// Auth → URL Configuration → Redirect URLs list.
    ///
    /// - Parameter redirectURL: e.g. `yentl://auth-callback` for the consumer app.
    public func signInWithGoogle(redirectURL: URL) async throws {
        do {
            _ = try await Backend.supabase.auth.signInWithOAuth(
                provider: .google,
                redirectTo: redirectURL,
                scopes: "email profile"
            )
        } catch {
            throw AuthError.unexpected(error)
        }
    }

    /// Stub: throws until the Apple Developer Program is active.
    ///
    /// Tracked in `docs/implementation-plan.md` Phase 8 — the App Store
    /// guideline 4.8 pairing with Google means we always ship both
    /// providers, so this stub gets replaced (not removed) at Phase 8.
    public func signInWithApple() async throws {
        throw AuthError.appleSignInPendingDeveloperAccount
    }

    public func signOut() async throws {
        do {
            try await Backend.supabase.auth.signOut()
        } catch {
            throw AuthError.unexpected(error)
        }
    }

    // MARK: - Role lookup

    /// Fetches the current user's role from `public.users`. Requires a signed-in session.
    public func fetchCurrentUserRole() async throws -> UserRole {
        guard case .signedIn(let user) = state else {
            throw AuthError.notSignedIn
        }
        do {
            let row: UserRoleRow = try await Backend.supabase
                .from("users")
                .select("role")
                .eq("id", value: user.id)
                .single()
                .execute()
                .value
            return row.role
        } catch {
            throw AuthError.unexpected(error)
        }
    }

    // MARK: - Onboarding

    /// Whether the signed-in user has finished the post-sign-in onboarding
    /// flow (welcome + privacy + terms/consent + 18+). Backed by
    /// `public.users.onboarding_completed_at`. Requires a signed-in session.
    public func isOnboardingComplete() async throws -> Bool {
        guard case .signedIn(let user) = state else {
            throw AuthError.notSignedIn
        }
        do {
            let row: OnboardingRow = try await Backend.supabase
                .from("users")
                .select("onboarding_completed_at")
                .eq("id", value: user.id)
                .single()
                .execute()
                .value
            return row.onboardingCompletedAt != nil
        } catch {
            throw AuthError.unexpected(error)
        }
    }

    /// Records the user's onboarding consent server-side via the
    /// `complete_onboarding` RPC (stamps terms / 18+ / completion timestamps
    /// for the calling user). Requires a signed-in session.
    public func completeOnboarding() async throws {
        guard case .signedIn = state else {
            throw AuthError.notSignedIn
        }
        do {
            try await Backend.supabase
                .rpc("complete_onboarding")
                .execute()
        } catch {
            throw AuthError.unexpected(error)
        }
    }

    // MARK: - Private

    /// Hydrates initial state then listens for changes from Supabase Auth.
    private func observeAuthChanges() async {
        // Initial state — async session lookup.
        do {
            let session = try await Backend.supabase.auth.session
            state = .signedIn(user: session.user)
        } catch {
            state = .signedOut
        }

        // Stream of auth state changes.
        for await (event, session) in Backend.supabase.auth.authStateChanges {
            switch event {
            case .signedIn, .tokenRefreshed, .userUpdated, .initialSession:
                if let session {
                    state = .signedIn(user: session.user)
                }
            case .signedOut:
                state = .signedOut
            default:
                break
            }
        }
    }

    private struct UserRoleRow: Decodable {
        let role: UserRole
    }

    private struct OnboardingRow: Decodable {
        let onboardingCompletedAt: String?

        enum CodingKeys: String, CodingKey {
            case onboardingCompletedAt = "onboarding_completed_at"
        }
    }
}
