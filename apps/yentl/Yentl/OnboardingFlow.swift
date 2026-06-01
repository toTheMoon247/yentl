//
//  OnboardingFlow.swift
//  Yentl
//
//  Lightweight post-sign-in onboarding: welcome → privacy note →
//  terms/consent + 18+ confirmation. Shown once, when the signed-in user's
//  `onboarding_completed_at` is still null. On completion it records consent
//  server-side via AuthService.completeOnboarding() and calls `onComplete`,
//  which routes the app to the home screen.
//
//  Full Terms / Privacy pages and stricter age verification land in Phase 11;
//  this is the MVP consent step.
//

import SwiftUI
import YentlShared

struct OnboardingFlow: View {
    /// Called after consent has been recorded server-side.
    let onComplete: () -> Void

    @Environment(AuthService.self) private var auth
    @State private var step: Step = .welcome
    @State private var agreedToTerms = false
    @State private var confirmedAge = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private enum Step {
        case welcome, privacy, consent
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
            Text("Your profile is reviewed by Yentl's professional matchmakers to make thoughtful introductions. We only share your profile with potential matches — never sold to advertisers. You're in control and can sign out any time.")
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
            onComplete()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    OnboardingFlow(onComplete: {})
        .environment(AuthService.shared)
}
