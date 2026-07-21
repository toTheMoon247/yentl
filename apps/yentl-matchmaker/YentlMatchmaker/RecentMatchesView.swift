//
//  RecentMatchesView.swift
//  YentlMatchmaker
//
//  Recent-matches dashboard (Phase 6 Slice 3): the latest matches across all
//  users, newest first — who was paired with whom, the state, and a live
//  countdown while a match is pending. Tapping a row offers each participant's
//  full match history.
//
//  Participant names come from a LEFT JOIN on profiles server-side, so a
//  missing profile row shows as "Unknown user" (and gets no history link,
//  since the RPC then has no id for them either).
//

import SwiftUI
import YentlShared

struct RecentMatchesView: View {
    @Environment(MatchmakerService.self) private var matchmaker

    /// Pushed per-user history target (participant chosen from a row).
    private struct HistoryTarget: Hashable {
        let id: UUID
        let name: String?
    }

    @State private var path: [HistoryTarget] = []
    @State private var rows: [RecentMatchEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Row awaiting the "whose history?" choice.
    @State private var choosing: RecentMatchEntry?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Matches")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        SignOutButton()
                    }
                }
                .navigationDestination(for: HistoryTarget.self) { target in
                    MatchHistoryView(userID: target.id, displayName: target.name)
                }
                .task { await load() }
                .refreshable { await load() }
                .confirmationDialog(
                    "View match history",
                    isPresented: Binding(get: { choosing != nil },
                                         set: { if !$0 { choosing = nil } }),
                    titleVisibility: .visible,
                    presenting: choosing
                ) { entry in
                    if let id = entry.userAID {
                        Button(entry.userAName ?? "Unknown user") {
                            path.append(HistoryTarget(id: id, name: entry.userAName))
                        }
                    }
                    if let id = entry.userBID {
                        Button(entry.userBName ?? "Unknown user") {
                            path.append(HistoryTarget(id: id, name: entry.userBName))
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
        } else if let errorMessage {
            MatchListMessage(icon: "exclamationmark.triangle",
                             title: "Something went wrong",
                             message: errorMessage)
        } else if rows.isEmpty {
            MatchListMessage(icon: "heart.text.square",
                             title: "No matches yet",
                             message: "Matches created in the Decision Panel will show up here.")
        } else {
            List(rows) { entry in
                Button { choosing = entry } label: { row(entry) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func row(_ entry: RecentMatchEntry) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Text("\(entry.userAName ?? "Unknown user") & \(entry.userBName ?? "Unknown user")")
                    .font(DesignTokens.Typography.body)
                Spacer()
                MatchStateBadge(state: entry.state)
            }
            MatchTimeline(state: entry.state,
                          createdAt: entry.createdAt,
                          resolvedAt: entry.resolvedAt,
                          expiresAt: entry.expiresAt)
            Text(responsesLine(entry))
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private func responsesLine(_ entry: RecentMatchEntry) -> String {
        let a = entry.userAName ?? "Unknown user"
        let b = entry.userBName ?? "Unknown user"
        return "\(a): \(MatchWording.response(entry.userAResponse))"
            + " · \(b): \(MatchWording.response(entry.userBResponse))"
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            rows = try await matchmaker.recentMatches()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
