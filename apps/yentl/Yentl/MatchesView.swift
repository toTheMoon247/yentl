//
//  MatchesView.swift
//  Yentl
//
//  The consumer's matches: a matchmaker-created match shows here with the other
//  person's profile, a 24h countdown, and Accept / Reject. (Real push arrives
//  in Phase 8; for now matches surface in-app.) Outcome polish + history come
//  with Slice 2/3.
//

import SwiftUI
import YentlShared

struct MatchesView: View {
    @Environment(MatchService.self) private var matchService

    @State private var matches: [MatchSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selected: MatchSummary?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Matches")
        }
        .task { await load() }
        .sheet(item: $selected) { match in
            MatchDetailView(match: match) {
                selected = nil
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
        } else if let errorMessage {
            messageState("exclamationmark.triangle", "Something went wrong", errorMessage)
        } else if matches.isEmpty {
            messageState("heart", "No matches yet",
                         "When a matchmaker pairs you with someone, they'll show up here.")
        } else {
            List(matches) { match in
                Button { selected = match } label: { row(match) }
            }
        }
    }

    private func row(_ match: MatchSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(match.otherProfile.age.map { "\(match.otherDisplayName), \($0)" }
                     ?? match.otherDisplayName)
                    .font(DesignTokens.Typography.body)
                Text(MatchStatus.line(for: match))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
            Spacer()
            if match.state == .pending && !match.hasResponded {
                Text("New")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DesignTokens.Palette.primary)
            }
        }
    }

    private func messageState(_ icon: String, _ title: String, _ message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            Text(title).font(DesignTokens.Typography.titleMedium)
            Text(message)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            matches = try await matchService.myMatches()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Full match detail: the other person's profile + status, with Accept/Reject
/// while the match is pending and unanswered.
private struct MatchDetailView: View {
    let match: MatchSummary
    let onResolved: () -> Void

    @Environment(ProfileService.self) private var profiles
    @Environment(MatchService.self) private var matchService
    @Environment(\.dismiss) private var dismiss

    @State private var photoURLs: [URL] = []
    @State private var prompts: [ProfilePrompt] = []
    @State private var isResponding = false
    @State private var errorMessage: String?
    @State private var showingChat = false

    private var canRespond: Bool {
        match.state == .pending && !match.hasResponded
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    PublicProfileCard(profile: match.otherProfile, photoURLs: photoURLs, prompts: prompts)
                    statusBanner
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.top, DesignTokens.Spacing.md)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.red)
                            .padding(.top, DesignTokens.Spacing.sm)
                    }
                }
                if canRespond { responseBar }
            }
            .navigationTitle(match.otherDisplayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
            }
            .navigationDestination(isPresented: $showingChat) {
                MatchConversationView(match: match)
                    .navigationTitle(match.otherDisplayName)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await loadMedia() }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch match.state {
        case .pending where match.hasResponded:
            label("You're in — waiting for them to respond.", "hourglass", .secondary)
        case .pending:
            TimelineView(.periodic(from: .now, by: 60)) { context in
                label(MatchStatus.countdown(to: match.expiresAt, now: context.date),
                      "clock", DesignTokens.Palette.primary)
            }
        case .confirmed:
            // A confirmed match is the entry point to chat (Phase 7).
            VStack(spacing: DesignTokens.Spacing.md) {
                label("It's a match! 🎉", "checkmark.seal.fill", .green)
                Button {
                    showingChat = true
                } label: {
                    Label("Open chat", systemImage: "bubble.left.and.bubble.right.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .controlSize(.large)
            }
        case .rejected:
            // Deliberately does not say who declined: the user learns the
            // match is over without being told they were the one rejected.
            label("This match wasn't accepted by both people.",
                  "xmark.circle", .secondary)
        case .expired:
            label("This match expired.", "clock.badge.xmark", .secondary)
        }
    }

    private func label(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(DesignTokens.Typography.body)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
    }

    private var responseBar: some View {
        HStack(spacing: DesignTokens.Spacing.xl) {
            Button(role: .destructive) {
                Task { await respond(false) }
            } label: {
                Label("Pass", systemImage: "xmark").frame(maxWidth: .infinity)
            }
            Button {
                Task { await respond(true) }
            } label: {
                Label("Accept", systemImage: "heart.fill").frame(maxWidth: .infinity)
            }
            .tint(.pink)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isResponding)
        .padding(DesignTokens.Spacing.lg)
    }

    private func loadMedia() async {
        do {
            let photos = try await profiles.listPhotos(userID: match.otherID)
            var urls: [URL] = []
            for photo in photos {
                if let url = try? await profiles.signedPhotoURL(for: photo.storagePath) {
                    urls.append(url)
                }
            }
            photoURLs = urls
            prompts = try await profiles.listPrompts(userID: match.otherID)
        } catch {
            // Non-fatal: show the card without media.
        }
    }

    private func respond(_ accept: Bool) async {
        isResponding = true
        defer { isResponding = false }
        do {
            try await matchService.respond(matchID: match.matchID, accept: accept)
            onResolved()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Status text helpers for matches.
private enum MatchStatus {
    static func line(for match: MatchSummary) -> String {
        switch match.state {
        case .pending where match.hasResponded: return "Waiting for them"
        // Derived from AppConfig rather than hardcoded "24h", which was wrong
        // in DEBUG builds (5-minute window) and would be wrong again if the
        // release window ever changed.
        case .pending: return "New match — respond within \(responseWindow)"
        case .confirmed: return "It's a match!"
        case .rejected: return "Not accepted by both"
        case .expired: return "Expired"
        }
    }

    /// The configured response window, as a short human phrase ("24h", "5m").
    static var responseWindow: String {
        let seconds = AppConfig.matchExpirySeconds
        let hours = seconds / 3600
        return hours >= 1 ? "\(hours)h" : "\(max(1, seconds / 60))m"
    }

    static func countdown(to expiry: Date, now: Date) -> String {
        let seconds = Int(expiry.timeIntervalSince(now))
        guard seconds > 0 else { return "Time's up" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m left to decide" : "\(minutes)m left to decide"
    }
}
