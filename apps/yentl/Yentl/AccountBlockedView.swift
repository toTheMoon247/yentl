//
//  AccountBlockedView.swift
//  Yentl
//
//  Phase 11 Slice 1: the consumer-side gate for a suspended or banned account.
//  Shown ahead of everything else (before onboarding / profile / review) when
//  `account_is_blocked` is true, so a moderated user can't use the app — only
//  read why and sign out. A lapsed suspension is NOT blocked (handled by the
//  routing in ContentView), so this screen only ever shows an active block.
//

import SwiftUI
import YentlShared

struct AccountBlockedView: View {
    let status: AccountStatus

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()
            Image(systemName: iconName)
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text(title)
                .font(DesignTokens.Typography.titleMedium)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let reason = status.moderationReason, !reason.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("Reason")
                        .font(DesignTokens.Typography.caption.weight(.semibold))
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                    Text(reason)
                        .font(DesignTokens.Typography.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignTokens.Spacing.md)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md))
            }
            Text("If you think this is a mistake, contact support@yentl.app.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            SignOutButton()
        }
        .padding(DesignTokens.Spacing.xl)
    }

    private var iconName: String {
        status.kind == .banned ? "nosign" : "clock.badge.xmark"
    }

    private var title: String {
        status.kind == .banned
            ? "Your account has been banned"
            : "Your account is suspended"
    }

    private var detail: String? {
        switch status.kind {
        case .banned:
            return "You no longer have access to Yentl."
        case .suspended:
            guard let until = status.suspendedUntil else {
                return "Your account is temporarily suspended."
            }
            return "Access returns on \(until.formatted(date: .abbreviated, time: .shortened))."
        case .active:
            return nil
        }
    }
}
