//
//  OnboardingFlow.swift
//  Yentl
//
//  Lightweight post-sign-in onboarding: welcome → privacy note →
//  terms/consent + 18+ confirmation → notifications. Shown once, when the
//  signed-in user's `onboarding_completed_at` is still null. The consent step
//  records consent server-side via AuthService.completeOnboarding(); the
//  final step asks for push permission (Phase 8 — this is the ONE place the
//  system prompt fires, so it is asked exactly once, at a moment the user
//  chose to be here, never on every home appearance); then `onComplete`
//  routes the app onward.
//
//  Full Terms / Privacy pages and stricter age verification land in Phase 11;
//  this is the MVP consent step.
//

import OneSignalFramework
import SwiftUI
import YentlShared

struct OnboardingFlow: View {
    /// Called after consent has been recorded server-side.
    let onComplete: () -> Void

    @Environment(AuthService.self) private var auth
    @State private var step: Step = .welcome
    @State private var agreedToTerms = false
    @State private var presentedDocument: LegalDocument?
    @State private var confirmedAge = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private enum Step {
        case welcome, privacy, consent, notifications
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xl) {
            switch step {
            case .welcome:
                welcome
            case .privacy:
                privacy
            case .consent:
                consent
            case .notifications:
                notifications
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .animation(.default, value: step)
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()
            Image(systemName: "heart.text.square")
                .font(.system(size: 56))
                .foregroundStyle(DesignTokens.Palette.primary)
            Text("Welcome to Yentl")
                .font(DesignTokens.Typography.titleLarge)
                .multilineTextAlignment(.center)
            Text("Real matchmakers — not algorithms — introduce you to people worth meeting. A few quick things before we start.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                step = .privacy
            } label: {
                Text("Get started")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignTokens.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var privacy: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(DesignTokens.Palette.primary)
            Text("Your privacy")
                .font(DesignTokens.Typography.titleMedium)
                .multilineTextAlignment(.center)
            Text(
                "Your profile is reviewed by Yentl's professional matchmakers "
                + "to make thoughtful introductions. We only share your profile "
                + "with potential matches — never sold to advertisers. You're in "
                + "control and can sign out any time."
            )
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                step = .consent
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignTokens.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var consent: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()
            Text("A couple of agreements")
                .font(DesignTokens.Typography.titleMedium)
                .multilineTextAlignment(.center)

            VStack(spacing: DesignTokens.Spacing.md) {
                Toggle(isOn: $agreedToTerms) {
                    Text("I agree to Yentl's Terms of Service and Privacy Policy.")
                        .font(DesignTokens.Typography.body)
                }
                Toggle(isOn: $confirmedAge) {
                    Text("I confirm that I am 18 years of age or older.")
                        .font(DesignTokens.Typography.body)
                }
            }
            .disabled(isSubmitting)

            HStack(spacing: DesignTokens.Spacing.lg) {
                Button("Terms of Service") { presentedDocument = .termsOfService }
                Button("Privacy Policy") { presentedDocument = .privacyPolicy }
            }
            .font(DesignTokens.Typography.caption)

            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                Task { await submit() }
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("Agree & continue")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignTokens.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue || isSubmitting)
        }
        .sheet(item: $presentedDocument) { document in
            NavigationStack {
                LegalDocumentView(document: document)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { presentedDocument = nil }
                        }
                    }
            }
        }
    }

    /// Phase 8: the push-permission moment. Onboarding is the one time we
    /// know the user is paying attention and hasn't been asked before, so the
    /// system prompt lives here — never on home appearance. "Not now" is a
    /// first-class path: iOS Settings and the in-app toggles remain available.
    private var notifications: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()
            Image(systemName: "bell.badge")
                .font(.system(size: 56))
                .foregroundStyle(DesignTokens.Palette.primary)
            Text("Don't miss a match")
                .font(DesignTokens.Typography.titleMedium)
                .multilineTextAlignment(.center)
            Text(
                "Matches on Yentl expire after 24 hours, so timing matters. "
                + "Allow notifications and we'll tell you the moment a "
                + "matchmaker introduces you to someone — and when they write "
                + "back. You can fine-tune this any time in your profile "
                + "settings."
            )
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                // fallbackToSettings: false — someone who declines the system
                // sheet is not bounced to iOS Settings mid-onboarding.
                OneSignal.Notifications.requestPermission({ _ in
                    // Continue regardless of the answer; the completion may
                    // arrive off-main.
                    DispatchQueue.main.async { onComplete() }
                }, fallbackToSettings: false)
            } label: {
                Text("Enable notifications")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignTokens.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
            Button("Not now") { onComplete() }
                .font(DesignTokens.Typography.body)
        }
    }

    // MARK: - Actions

    private var canContinue: Bool {
        agreedToTerms && confirmedAge
    }

    private func submit() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await auth.completeOnboarding()
            // Consent is recorded; the notifications ask is best-effort last.
            // (If the app dies right here the user simply lands on home next
            // launch, un-prompted — acceptable for a permission nicety.)
            step = .notifications
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    OnboardingFlow(onComplete: {})
        .environment(AuthService.shared)
}
