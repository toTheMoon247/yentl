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
    @Environment(ChatService.self) private var chat
    @State private var stage: AccountStage?
    @State private var statusError: String?

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                ProgressView()
            case .signedOut:
                YentlAuthFlow(config: .yentl)
                    .onAppear { stage = nil; statusError = nil }
                    #if DEBUG
                    .modifier(SignedOutTestLoginButton())
                    #endif
            case .signedIn:
                signedInContent
                    .task(id: signedInUserID) { await loadStage() }
            }
        }
        // The Stream connection follows the Supabase session: connect on
        // sign-in (or account switch), disconnect on sign-out. Lowercased id:
        // Stream user ids are the lowercase Supabase UUIDs (the exact string
        // the stream-token function mints tokens for).
        .task(id: auth.currentUserIDString) {
            // Identity changed: drop the per-session ensured-channel cache so
            // the next account re-verifies its own channels server-side.
            StreamChannelService.shared.reset()
            if let id = auth.currentUserIDString {
                let name = (try? await profiles.fetchMyProfile())?.displayName
                await chat.connect(userID: id.lowercased(), displayName: name)
            } else if case .signedOut = auth.state {
                await chat.disconnect()
            }
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
            MatchesView()
                .tabItem { Label("Matches", systemImage: "heart") }
            ChatInboxView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
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
    #if DEBUG
    @State private var showingTestLogin = false
    #endif

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
                #if DEBUG
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingTestLogin = true } label: { Image(systemName: "ladybug") }
                        .accessibilityIdentifier("debug-test-login")
                }
                #endif
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
        #if DEBUG
        .sheet(isPresented: $showingTestLogin) {
            TestLoginPicker(onSwitched: { showingTestLogin = false })
        }
        #endif
    }
}

#if DEBUG
/// DEBUG-only: exposes the test-login picker from the *signed-out* screen.
///
/// TestLoginPicker normally lives behind the Profile tab, which is only
/// reachable once signed in — so on a fresh install (new simulator, no
/// session) there was no way to sign in as a seed at all: the signed-out
/// screen offers only Google/Apple OAuth. This ladybug overlay closes that
/// gap so the app can be driven unattended, mirroring the matchmaker app's
/// `debugSignInEmail` escape hatch. Never compiled into release builds.
private struct SignedOutTestLoginButton: ViewModifier {
    @State private var showingPicker = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                Button {
                    showingPicker = true
                } label: {
                    Image(systemName: "ladybug")
                        .font(.title3)
                        .padding(DesignTokens.Spacing.lg)
                }
                .accessibilityIdentifier("debug-test-login")
            }
            .sheet(isPresented: $showingPicker) {
                TestLoginPicker(onSwitched: { showingPicker = false })
            }
    }
}
#endif

#Preview {
    ContentView()
        .environment(AuthService.shared)
        .environment(ProfileService.shared)
        .environment(DiscoveryService.shared)
        .environment(MatchService.shared)
        .environment(ChatService.shared)
}
