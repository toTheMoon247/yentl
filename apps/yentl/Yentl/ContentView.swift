//
//  ContentView.swift
//  Yentl
//

import SwiftUI
import YentlShared

/// Root of the Yentl consumer app — routes on `AuthService.state`.
struct ContentView: View {
    @Environment(AuthService.self) private var auth

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut:
            YentlAuthFlow(config: .yentl)
        case .signedIn:
            SignedInHomeView()
        }
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
