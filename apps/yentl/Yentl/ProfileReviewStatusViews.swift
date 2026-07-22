//
//  ProfileReviewStatusViews.swift
//  Yentl
//
//  Phase 12 (Slice 3): the consumer-side approval states. Shown by
//  ContentView when a completed profile is not (yet) live:
//    - ProfileUnderReviewView    review_state = pending_ai / pending_review
//    - ProfileNeedsChangesView   review_state = rejected
//  Neither screen ever surfaces internal state names, tokens, or AI category
//  slugs — the copy is warm and actionable, via RejectionFeedback.
//

import SwiftUI
import YentlShared

/// "Your profile is being reviewed" — the holding screen while screening or
/// a matchmaker look is in progress. The user is not in discovery yet.
struct ProfileUnderReviewView: View {
    /// Re-checks the account stage (review may have finished).
    let onRefresh: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: DesignTokens.Spacing.lg) {
                Spacer()
                Image(systemName: "hourglass")
                    .font(.system(size: 56))
                    .foregroundStyle(DesignTokens.Palette.primary)
                Text("Your profile is being reviewed")
                    .font(DesignTokens.Typography.titleMedium)
                    .multilineTextAlignment(.center)
                Text("Thanks for setting everything up! Our matchmakers are "
                     + "taking a look at your profile. We'll let you know as "
                     + "soon as you're ready to start matching — it usually "
                     + "doesn't take long.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Spacer()
                Button("Check status", action: onRefresh)
                    .buttonStyle(.borderedProminent)
            }
            .padding(DesignTokens.Spacing.xl)
            .toolbar { ReviewStatusToolbar() }
        }
    }
}

/// "Your profile needs a few changes" — shown after a matchmaker rejection,
/// with the reason mapped to friendly copy and an Edit & resubmit path back
/// through EditProfileView → markProfileComplete → screening.
struct ProfileNeedsChangesView: View {
    /// Raw `profile_moderation.decision_reason` ("token" / "token: note");
    /// parsed here, never displayed as-is.
    let reasonText: String?
    /// Called after a successful resubmit so the parent re-routes (approval
    /// ON → under review; OFF → straight into the app).
    let onResubmitted: () -> Void

    @Environment(ProfileService.self) private var profiles
    @State private var showingEdit = false
    @State private var savedInEditor = false
    @State private var isResubmitting = false
    @State private var errorMessage: String?

    private var feedback: RejectionFeedback { RejectionFeedback.parse(reasonText) }

    var body: some View {
        NavigationStack {
            VStack(spacing: DesignTokens.Spacing.lg) {
                Spacer()
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 56))
                    .foregroundStyle(DesignTokens.Palette.primary)
                Text("Your profile needs a few changes")
                    .font(DesignTokens.Typography.titleMedium)
                    .multilineTextAlignment(.center)
                Text(feedback.message)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                if let note = feedback.note {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text("A note from your matchmaker")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Palette.textSecondary)
                        Text(note)
                            .font(DesignTokens.Typography.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md)
                            .fill(DesignTokens.Palette.primary.opacity(0.08))
                    )
                }
                Text("Update your profile and resubmit — we'll take another "
                     + "look right away.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                if let errorMessage {
                    Text(errorMessage)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                Button {
                    showingEdit = true
                } label: {
                    HStack {
                        Spacer()
                        if isResubmitting {
                            ProgressView()
                        } else {
                            Text("Edit & resubmit")
                        }
                        Spacer()
                    }
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResubmitting)
            }
            .padding(DesignTokens.Spacing.xl)
            .toolbar { ReviewStatusToolbar() }
        }
        .sheet(isPresented: $showingEdit) {
            EditProfileView(
                onDone: { showingEdit = false },
                onSaved: { savedInEditor = true }
            )
            .interactiveDismissDisabled(isResubmitting)
        }
        .onChange(of: showingEdit) { _, isShowing in
            // Resubmit only after the sheet closed via Save (cancel keeps the
            // profile as-is, so there is nothing new to submit).
            guard !isShowing, savedInEditor else { return }
            savedInEditor = false
            Task { await resubmit() }
        }
    }

    private func resubmit() async {
        errorMessage = nil
        isResubmitting = true
        defer { isResubmitting = false }
        do {
            // Same write as finishing the wizard: approval ON coerces it to
            // pending_ai; OFF takes it straight to live.
            try await profiles.markProfileComplete()
            // Best-effort screening; a failure just leaves the state for the
            // re-read below (never strands the user).
            await profiles.requestScreening()
            onResubmitted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Shared toolbar for both status screens: sign-out (the user has no other
/// screen to reach it from) and, in DEBUG, the seed-account switcher so the
/// app stays drivable when a seed is parked in a review state.
private struct ReviewStatusToolbar: ToolbarContent {
    #if DEBUG
    @State private var showingTestLogin = false
    #endif

    var body: some ToolbarContent {
        #if DEBUG
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showingTestLogin = true
            } label: {
                Image(systemName: "ladybug")
            }
            .accessibilityIdentifier("debug-test-login")
            .sheet(isPresented: $showingTestLogin) {
                TestLoginPicker(onSwitched: { showingTestLogin = false })
            }
        }
        #endif
        ToolbarItem(placement: .topBarTrailing) {
            SignOutButton()
        }
    }
}

#Preview("Under review") {
    ProfileUnderReviewView(onRefresh: {})
}

#Preview("Needs changes") {
    ProfileNeedsChangesView(
        reasonText: "contact_info_in_bio: Please drop the Instagram handle from your bio.",
        onResubmitted: {}
    )
    .environment(ProfileService.shared)
}
