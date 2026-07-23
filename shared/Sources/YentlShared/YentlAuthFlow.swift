import SwiftUI

/// Per-app configuration for the shared sign-in flow.
///
/// Carries the app-facing strings and the OAuth redirect URL (must match
/// the URL scheme registered in the host app's Info.plist *and* the
/// Redirect URL list in Supabase's Authentication → URL Configuration).
public struct AuthFlowConfig: Sendable {
    public let appTitle: String
    public let appTagline: String
    public let redirectURL: URL
    /// DEBUG only: a seeded email/password account this app can sign in as with
    /// one tap, bypassing OAuth. `nil` hides the shortcut.
    ///
    /// Exists because the matchmaker app otherwise offers only Google / Apple,
    /// which cannot be driven unattended — so the Decision Panel, and with it
    /// the whole match lifecycle, was untestable without a human at the
    /// keyboard. The consumer app has its own richer picker (TestLoginPicker)
    /// and leaves this `nil`. Set up by supabase/dev/seed_staff_account.sql.
    public let debugSignInEmail: String?

    public init(
        appTitle: String,
        appTagline: String,
        redirectURL: URL,
        debugSignInEmail: String? = nil
    ) {
        self.appTitle = appTitle
        self.appTagline = appTagline
        self.redirectURL = redirectURL
        self.debugSignInEmail = debugSignInEmail
    }
}

public extension AuthFlowConfig {
    /// Configuration for the Yentl consumer app.
    static let yentl = AuthFlowConfig(
        appTitle: "Yentl",
        appTagline: "Real matchmakers. Real dates.",
        redirectURL: URL(string: "yentl://auth-callback")!
    )

    /// Configuration for the Yentl Matchmaker internal app.
    static let matchmaker = AuthFlowConfig(
        appTitle: "Yentl Matchmaker",
        appTagline: "Internal matchmaking tool.",
        redirectURL: URL(string: "yentl-matchmaker://auth-callback")!,
        debugSignInEmail: "seed-staff-01@yentl.test"
    )
}

/// Sign-in screen shared between Yentl and Yentl Matchmaker.
public struct YentlAuthFlow: View {
    public let config: AuthFlowConfig

    @Environment(AuthService.self) private var auth
    @State private var errorMessage: String?
    @State private var isWorking = false

    public init(config: AuthFlowConfig) {
        self.config = config
    }

    public var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()

            VStack(spacing: DesignTokens.Spacing.sm) {
                Text(config.appTitle)
                    .font(DesignTokens.Typography.titleLarge)
                Text(config.appTagline)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: DesignTokens.Spacing.md) {
                Button {
                    Task { await handle(.apple) }
                } label: {
                    Label("Continue with Apple", systemImage: "apple.logo")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)
                .disabled(isWorking)

                Button {
                    Task { await handle(.google) }
                } label: {
                    Text("Continue with Google")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.sm)
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)

                #if DEBUG
                if let debugEmail = config.debugSignInEmail {
                    Button {
                        Task { await signInAsDebugAccount(debugEmail) }
                    } label: {
                        Label("Sign in as test staff (DEBUG)", systemImage: "ladybug")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DesignTokens.Spacing.sm)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .disabled(isWorking)
                }
                #endif
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, DesignTokens.Spacing.sm)
            }
        }
        .padding(DesignTokens.Spacing.xl)
    }

    private enum Provider {
        case apple, google
    }

    #if DEBUG
    /// Shared password for every seeded account (supabase/dev/set_seed_passwords.sql).
    private static let debugPassword = "yentltest"

    private func signInAsDebugAccount(_ email: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await auth.signInWithEmail(email, password: Self.debugPassword)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    private func handle(_ provider: Provider) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            switch provider {
            case .apple:
                try await auth.signInWithApple()
            case .google:
                try await auth.signInWithGoogle(redirectURL: config.redirectURL)
            }
        } catch is CancellationError {
            // User dismissed the provider sheet — not an error worth showing.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
