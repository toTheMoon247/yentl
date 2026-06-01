//
//  ContentView.swift
//  Yentl
//

import SwiftUI
import YentlShared

/// Root of the Yentl consumer app — routes on `AuthService.state`, then on
/// whether the signed-in user has completed onboarding.
struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @State private var onboarded: Bool?
    @State private var statusError: String?

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut:
            YentlAuthFlow(config: .yentl)
                .onAppear { onboarded = nil; statusError = nil }
        case .signedIn:
            signedInContent
                .task(id: signedInUserID) { await loadStatus() }
        }
    }

    /// Stable identity for `.task(id:)` so the onboarding check re-runs when
    /// the signed-in user changes (sign out → sign in as someone else).
    private var signedInUserID: String {
        auth.currentUserIDString ?? ""
    }

    @ViewBuilder
    private var signedInContent: some View {
        if let isOnboarded = onboarded {
            if isOnboarded {
                SignedInHomeView()
            } else {
                OnboardingFlow(onComplete: { onboarded = true })
            }
        } else if let statusError {
            OnboardingStatusErrorView(message: statusError) {
                Task { await loadStatus() }
            }
        } else {
            ProgressView("Getting things ready…")
        }
    }

    private func loadStatus() async {
        statusError = nil
        do {
            onboarded = try await auth.isOnboardingComplete()
        } catch {
            onboarded = nil
            statusError = error.localizedDescription
        }
    }
}

/// Shown when the post-sign-in onboarding check fails (e.g. network error).
private struct OnboardingStatusErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(DesignTokens.Typography.titleMedium)
            Text(message)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(DesignTokens.Spacing.xl)
    }
}

/// Placeholder home for signed-in users. Replaced with real content in Phase 2.
private struct SignedInHomeView: View {
    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()
            Text("Welcome to Yentl")
                .font(DesignTokens.Typography.titleLarge)
            Text("You're signed in. Phase 2 work goes here.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            Spacer()
            SignOutButton()
        }
        .padding(DesignTokens.Spacing.xl)
    }
}

#Preview {
    ContentView()
        .environment(AuthService.shared)
}
