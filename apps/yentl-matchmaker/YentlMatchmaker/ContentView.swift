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

/// Staff home: browse completed profiles and open one to review (public
/// fields + the hidden matchmaker fields). A plain list for now — the
/// swipe-based Decision Panel and queue arrive in Phase 5.
private struct MatchmakerHomeView: View {
    @Environment(ProfileService.self) private var profiles

    @State private var rows: [Profile] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.red)
                } else if rows.isEmpty {
                    Text("No completed profiles yet.")
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                } else {
                    ForEach(rows) { profile in
                        NavigationLink {
                            ProfileScreen(userID: profile.id, showHiddenFields: true)
                                .navigationTitle(profile.displayName)
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName)
                                    .font(DesignTokens.Typography.body)
                                Text(subtitle(for: profile))
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Profiles")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SignOutButton()
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func subtitle(for profile: Profile) -> String {
        var parts = [profile.gender.displayName, profile.location]
        if let age = profile.age { parts.insert("\(age)", at: 1) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            rows = try await profiles.fetchAllCompletedProfiles()
        } catch {
            errorMessage = error.localizedDescription
        }
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
        .environment(ProfileService.shared)
}
