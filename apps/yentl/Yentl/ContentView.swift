//
//  ContentView.swift
//  Yentl
//

import SwiftUI
import YentlShared

/// The signed-in user's place in the account lifecycle. Drives which screen
/// the consumer app shows after authentication. (Pending / rejected states
/// arrive with the Phase 3/12 profile-approval work.)
private enum AccountStage {
    case needsOnboarding
    case needsProfile
    case ready
}

/// Root of the Yentl consumer app — routes on `AuthService.state`, then on
/// the signed-in user's account stage (onboarding → profile → ready).
struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(ProfileService.self) private var profiles
    @State private var stage: AccountStage?
    @State private var statusError: String?

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut:
            YentlAuthFlow(config: .yentl)
                .onAppear { stage = nil; statusError = nil }
        case .signedIn:
            signedInContent
                .task(id: signedInUserID) { await loadStage() }
        }
    }

    /// Stable identity for `.task(id:)` so the stage check re-runs when the
    /// signed-in user changes (sign out → sign in as someone else).
    private var signedInUserID: String {
        auth.currentUserIDString ?? ""
    }

    @ViewBuilder
    private var signedInContent: some View {
        if let stage {
            switch stage {
            case .needsOnboarding:
                OnboardingFlow(onComplete: { Task { await loadStage() } })
            case .needsProfile:
                ProfileWizard(onComplete: { Task { await loadStage() } })
            case .ready:
                SignedInHomeView()
            }
        } else if let statusError {
            AccountStageErrorView(message: statusError) {
                Task { await loadStage() }
            }
        } else {
            ProgressView("Getting things ready…")
        }
    }

    private func loadStage() async {
        statusError = nil
        stage = nil
        do {
            guard try await auth.isOnboardingComplete() else {
                stage = .needsOnboarding
                return
            }
            guard try await profiles.isProfileComplete() else {
                stage = .needsProfile
                return
            }
            stage = .ready
        } catch {
            statusError = error.localizedDescription
        }
    }
}

/// Shown when resolving the account stage fails (e.g. network error).
private struct AccountStageErrorView: View {
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

/// Home for signed-in users with a completed profile — a tab bar with the
/// discovery stack and the user's own profile.
private struct SignedInHomeView: View {
    var body: some View {
        TabView {
            DiscoveryView()
                .tabItem { Label("Discover", systemImage: "sparkles") }
            ProfileTab()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
    }
}

/// The user's own profile tab — shows their profile as others see it (no hidden
/// fields), with edit and sign-out.
private struct ProfileTab: View {
    @Environment(AuthService.self) private var auth
    @State private var showingEdit = false
    @State private var reloadID = 0

    var body: some View {
        NavigationStack {
            Group {
                if let userID = auth.currentUserIDString.flatMap(UUID.init) {
                    ProfileScreen(userID: userID, showHiddenFields: false)
                        .id(reloadID)
                } else {
                    Text("Couldn't load your profile.")
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                }
            }
            .navigationTitle("Your profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Edit") { showingEdit = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SignOutButton()
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            EditProfileView(onDone: {
                showingEdit = false
                reloadID += 1
            })
        }
    }
}

#Preview {
    ContentView()
        .environment(AuthService.shared)
        .environment(ProfileService.shared)
        .environment(DiscoveryService.shared)
}
