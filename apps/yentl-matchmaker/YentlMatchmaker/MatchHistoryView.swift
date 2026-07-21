//
//  MatchHistoryView.swift
//  YentlMatchmaker
//
//  Per-user match history (Phase 6 Slice 3): every match a user was part of,
//  newest first, with the other participant's name, the outcome, and both
//  sides' responses. Pushed from the Matches tab (per participant) and from
//  the Decision Panel (pinned user's history).
//
//  Names come from a LEFT JOIN on profiles server-side, so a participant
//  without a profile row renders as "Unknown user" rather than crashing or
//  dropping the match.
//

import SwiftUI
import YentlShared

struct MatchHistoryView: View {
    let userID: UUID
    /// The user's display name for titles and response lines; nil when the
    /// caller doesn't know it (e.g. a missing profile row).
    let displayName: String?

    @Environment(MatchmakerService.self) private var matchmaker

    @State private var rows: [MatchHistoryEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                MatchListMessage(icon: "exclamationmark.triangle",
                                 title: "Something went wrong",
                                 message: errorMessage)
            } else if rows.isEmpty {
                MatchListMessage(icon: "heart.slash",
                                 title: "No matches yet",
                                 message: "\(subjectName) hasn't been part of any match.")
            } else {
                List(rows) { entry in
                    row(entry)
                }
            }
        }
        .navigationTitle("\(subjectName)'s matches")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var subjectName: String {
        displayName ?? "This user"
    }

    private func row(_ entry: MatchHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Text(entry.otherDisplayName ?? "Unknown user")
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

    private func responsesLine(_ entry: MatchHistoryEntry) -> String {
        let other = entry.otherDisplayName ?? "Unknown user"
        return "\(subjectName): \(MatchWording.response(entry.targetResponse))"
            + " · \(other): \(MatchWording.response(entry.otherResponse))"
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            rows = try await matchmaker.matchHistory(for: userID)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Presentation helpers shared with the Matches (dashboard) tab

/// Capsule badge for a match state.
struct MatchStateBadge: View {
    let state: MatchState

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(color, in: Capsule())
    }

    private var label: String {
        switch state {
        case .pending: return "PENDING"
        case .confirmed: return "CONFIRMED"
        case .rejected: return "REJECTED"
        case .expired: return "EXPIRED"
        }
    }

    private var color: Color {
        switch state {
        case .pending: return .orange
        case .confirmed: return .green
        case .rejected: return .gray
        case .expired: return .gray
        }
    }
}

/// One caption line for a match's timing: when it was created, plus either a
/// live countdown (pending — ticks once a minute like the consumer app's) or
/// when it was resolved.
struct MatchTimeline: View {
    let state: MatchState
    let createdAt: Date
    let resolvedAt: Date?
    let expiresAt: Date

    var body: some View {
        Group {
            if state == .pending {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Label(
                        "Matched \(Self.short(createdAt)) · \(MatchWording.countdown(to: expiresAt, now: context.date))",
                        systemImage: "clock"
                    )
                    .foregroundStyle(DesignTokens.Palette.primary)
                }
            } else {
                Text(resolvedLine)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
        }
        .font(DesignTokens.Typography.caption)
    }

    private var resolvedLine: String {
        var line = "Matched \(Self.short(createdAt))"
        if let resolvedAt {
            line += " · resolved \(Self.short(resolvedAt))"
        }
        return line
    }

    static func short(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Wording helpers for match rows.
enum MatchWording {
    /// "accepted" / "rejected" / nil → a terse human word for a response cell.
    static func response(_ response: String?) -> String {
        response ?? "no reply"
    }

    static func countdown(to expiry: Date, now: Date) -> String {
        let seconds = Int(expiry.timeIntervalSince(now))
        guard seconds > 0 else { return "expiring…" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m left" : "\(minutes)m left"
    }
}

/// Centered icon + title + message, the app's standard list placeholder.
struct MatchListMessage: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
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
}
