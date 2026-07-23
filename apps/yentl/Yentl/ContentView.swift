//
//  ContentView.swift
//  Yentl
//

import OneSignalFramework
import SwiftUI
import YentlShared

/// The signed-in user's place in the account lifecycle. Drives which screen
/// the consumer app shows after authentication.
private enum AccountStage {
    /// Account suspended or banned by a matchmaker — gates everything else.
    case blocked(status: AccountStatus)
    case needsOnboarding
    case needsProfile
    /// Profile complete but review_state is pending_ai / pending_review
    /// (only reachable while profile approval is ON): not in discovery yet.
    case underReview
    /// Profile rejected by a matchmaker; carries the raw
    /// `profile_moderation.decision_reason` (parsed to friendly copy by the
    /// screen, never shown raw).
    case needsChanges(reasonText: String?)
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
        // The Stream and OneSignal identities follow the Supabase session:
        // connect/login on sign-in (or account switch), disconnect/logout on
        // sign-out. Lowercased id: Stream user ids are the lowercase Supabase
        // UUIDs (the exact string the stream-token function mints tokens
        // for), and OneSignal uses the same external id so pushes target the
        // same user.
        .task(id: auth.currentUserIDString) {
            // Identity changed: drop the per-user caches so the next account
            // re-verifies its channels and re-reads its own notification
            // preferences instead of inheriting the previous user's.
            StreamChannelService.shared.reset()
            NotificationPreferencesService.shared.reset()
            if let id = auth.currentUserIDString {
                OneSignal.login(id.lowercased())
                await PurchaseService.logIn(supabaseUserID: id)
                let name = (try? await profiles.fetchMyProfile())?.displayName
                await chat.connect(userID: id.lowercased(), displayName: name)
            } else if case .signedOut = auth.state {
                OneSignal.logout()
                await PurchaseService.logOut()
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
            case .blocked(let status):
                AccountBlockedView(status: status)
            case .needsOnboarding:
                OnboardingFlow(onComplete: { Task { await loadStage() } })
            case .needsProfile:
                // On finish, best-effort AI screening (approval ON moves the
                // profile from pending_ai; approval OFF or a failed call
                // changes nothing) — then route on whatever the server holds.
                ProfileWizard(onComplete: {
                    Task {
                        self.stage = nil  // spinner while screening + re-read run
                        await profiles.requestScreening()
                        await loadStage()
                    }
                })
            case .underReview:
                ProfileUnderReviewView(onRefresh: { Task { await loadStage() } })
            case .needsChanges(let reasonText):
                ProfileNeedsChangesView(
                    reasonText: reasonText,
                    onResubmitted: { Task { await loadStage() } }
                )
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
            // Moderation gate comes first: a suspended/banned account can't use
            // the app at all. A lapsed suspension is not blocked (isBlocked is
            // false), so it falls through to the normal flow. Failure to read
            // status is non-fatal — never lock a user out on a transient error.
            if let status = try? await ModerationService.shared.fetchMyAccountStatus(),
               status.isBlocked {
                stage = .blocked(status: status)
                return
            }
            guard try await auth.isOnboardingComplete() else {
                stage = .needsOnboarding
                return
            }
            guard try await profiles.isProfileComplete() else {
                stage = .needsProfile
                return
            }
            switch try await profiles.fetchMyReviewState() {
            case .pendingAI, .pendingReview:
                stage = .underReview
            case .rejected:
                let moderation = try? await profiles.fetchMyModeration()
                stage = .needsChanges(reasonText: moderation?.decisionReason)
            default:
                // .live — the only state a completed profile reaches while
                // approval is OFF (completion writes it directly), so today's
                // straight-into-the-app behavior is unchanged. draft / nil /
                // unknown also fall through to the full app rather than
                // stranding the user on a gate we can't explain.
                stage = .ready
            }
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
        // Note: the push-permission request no longer lives here — it moved
        // to its own step at the end of onboarding (OnboardingFlow), asked
        // once instead of on every home appearance. Users who decline can
        // enable pushes any time in iOS Settings; the in-app toggles live in
        // Profile → Notifications.
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
    @State private var showingNotificationSettings = false
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
                    Button {
                        showingNotificationSettings = true
                    } label: {
                        Image(systemName: "bell.badge")
                    }
                    .accessibilityIdentifier("notification-settings")
                    .accessibilityLabel("Notification settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SignOutButton()
                }
            }
            .navigationDestination(isPresented: $showingNotificationSettings) {
                NotificationSettingsView()
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
