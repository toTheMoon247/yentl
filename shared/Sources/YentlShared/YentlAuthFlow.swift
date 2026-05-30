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

    public init(appTitle: String, appTagline: String, redirectURL: URL) {
        self.appTitle = appTitle
        self.appTagline = appTagline
        self.redirectURL = redirectURL
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
        redirectURL: URL(string: "yentl-matchmaker://auth-callback")!
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
