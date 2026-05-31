//
//  ContentView.swift
//  YentlMatchmaker
//

import SwiftUI
import YentlShared

/// Root of the Yentl Matchmaker app — routes on auth state and then on role.
struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @State private var role: UserRole?
    @State private var roleFetchError: String?

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut:
            YentlAuthFlow(config: .matchmaker)
                .onAppear { role = nil; roleFetchError = nil }
        case .signedIn:
            signedInContent
                .task(id: signedInUserID) { await loadRole() }
        }
    }

    /// Stable identity for the `.task(id:)` modifier so the role fetch runs
    /// when the signed-in user changes (sign out → sign in as a different user).
    private var signedInUserID: String {
        auth.currentUserIDString ?? ""
    }

    @ViewBuilder
    private var signedInContent: some View {
        if let role {
            if role.isStaff {
                MatchmakerHomeView()
            } else {
                AccessPendingView()
            }
        } else if let roleFetchError {
            RoleFetchErrorView(message: roleFetchError) {
                Task { await loadRole() }
            }
        } else {
            ProgressView("Checking access…")
        }
    }

    private func loadRole() async {
        roleFetchError = nil
        do {
            role = try await auth.fetchCurrentUserRole()
        } catch {
            role = nil
            roleFetchError = error.localizedDescription
        }
    }
}

/// Placeholder home for staff users. Replaced with the Decision Panel and
/// matchmaker workflows in Phase 5.
private struct MatchmakerHomeView: View {
    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()
            Text("Yentl Matchmaker")
                .font(DesignTokens.Typography.titleLarge)
            Text("Signed in as staff. Decision Panel goes here in Phase 5.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            SignOutButton()
        }
        .padding(DesignTokens.Spacing.xl)
    }
}

/// Shown to signed-in users whose role is `user` (not yet promoted).
private struct AccessPendingView: View {
    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.clock")
                .font(.system(size: 56))
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            Text("Access pending")
                .font(DesignTokens.Typography.titleMedium)
            Text("Your account isn't set up as a matchmaker yet. Ask an admin to promote your role, then sign in again.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            SignOutButton()
        }
        .padding(DesignTokens.Spacing.xl)
    }
}

private struct RoleFetchErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Couldn't check your access")
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

#Preview {
    ContentView()
        .environment(AuthService.shared)
}
