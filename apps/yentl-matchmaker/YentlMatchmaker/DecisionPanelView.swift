//
//  DecisionPanelView.swift
//  YentlMatchmaker
//
//  The core matchmaker UX. Pins the front-of-queue user and shows their
//  mutual-like candidates (people who liked them AND whom they liked). Skip
//  advances the queue. When there are no candidates, a diagnostic (likes
//  received vs given) steers toward Boost (Phase 10) or Skip.
//
//  Slice 1: text-based rows + tap-through to the full profile. Photos in the
//  panel and a one-at-a-time candidate viewer are later polish. Creating a
//  match is Phase 6.
//

import SwiftUI
import YentlShared

struct DecisionPanelView: View {
    @Environment(MatchmakerService.self) private var matchmaker
    @Environment(ProfileService.self) private var profiles

    @State private var pinnedID: UUID?
    @State private var pinned: Profile?
    @State private var candidates: [Profile] = []
    @State private var stats: LikeStats?
    @State private var isLoading = true
    @State private var isSkipping = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Review")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { SignOutButton() }
                    if pinnedID != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Skip") { Task { await skip() } }
                                .disabled(isSkipping)
                        }
                    }
                }
                .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
        } else if let errorMessage {
            messageState("exclamationmark.triangle", "Something went wrong", errorMessage)
        } else if pinned == nil {
            messageState("checkmark.circle", "Queue is empty", "No one is waiting to be matched right now.")
        } else if let pinned {
            panel(for: pinned)
        }
    }

    private func panel(for pinned: Profile) -> some View {
        List {
            Section("Pinned") {
                NavigationLink {
                    ProfileScreen(userID: pinned.id, showHiddenFields: true)
                        .navigationTitle(pinned.displayName)
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    pinnedSummary(pinned)
                }
            }

            if candidates.isEmpty {
                Section("Candidates") { emptyCandidates }
            } else {
                Section("Mutual matches (\(candidates.count))") {
                    ForEach(candidates) { candidate in
                        NavigationLink {
                            ProfileScreen(userID: candidate.id, showHiddenFields: true)
                                .navigationTitle(candidate.displayName)
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            personRow(candidate)
                        }
                    }
                }
            }
        }
    }

    private func pinnedSummary(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            personRow(profile)
            HStack(spacing: DesignTokens.Spacing.md) {
                Label(profile.heightCm.map { "\($0) cm" } ?? "—", systemImage: "ruler")
                Label(profile.incomeAnnual.map { "\($0)" } ?? "—", systemImage: "banknote")
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Palette.textSecondary)
        }
    }

    private func personRow(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profile.age.map { "\(profile.displayName), \($0)" } ?? profile.displayName)
                .font(DesignTokens.Typography.body)
            Text("\(profile.gender.displayName) · \(profile.location)")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
        }
    }

    @ViewBuilder
    private var emptyCandidates: some View {
        Text("No mutual matches yet.")
            .foregroundStyle(DesignTokens.Palette.textSecondary)
        if let stats {
            Text("Likes received \(stats.received) · given \(stats.given)")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            Text(recommendation(for: stats))
                .font(DesignTokens.Typography.caption)
            if boostRecommended(for: stats) {
                Button("Boost (Phase 10)") {}
                    .disabled(true)
            }
        }
    }

    private func boostRecommended(for stats: LikeStats) -> Bool {
        // Active (giving likes) but not getting seen (not receiving) → boost.
        stats.given > 0 && stats.received == 0
    }

    private func recommendation(for stats: LikeStats) -> String {
        if stats.given == 0 {
            return "They haven't liked anyone yet — boosting won't help. Skip for now."
        }
        if stats.received == 0 {
            return "They're active but aren't being seen — consider a Boost."
        }
        return "They have likes both ways but no mutual yet. Skip for now."
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

    // MARK: - Data

    private func load() async {
        isLoading = true
        errorMessage = nil
        pinned = nil
        candidates = []
        stats = nil
        defer { isLoading = false }
        do {
            guard let id = try await matchmaker.nextQueuedUser() else {
                pinnedID = nil
                return
            }
            pinnedID = id
            pinned = try await profiles.fetchProfile(userID: id)
            candidates = try await matchmaker.candidates(for: id)
            if candidates.isEmpty {
                stats = try await matchmaker.likeStats(for: id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func skip() async {
        guard let id = pinnedID else { return }
        isSkipping = true
        defer { isSkipping = false }
        do {
            try await matchmaker.skip(userID: id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
