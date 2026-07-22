//
//  ApprovalsView.swift
//  YentlMatchmaker
//
//  Phase 12 Slice 2: the profile approval queue. Only AI-FLAGGED profiles
//  (review_state = 'pending_review') appear — clean profiles auto-approve and
//  never reach a human. The list shows newest-flagged first with a short flag
//  summary; the detail reuses the full-profile viewer (photos + hidden
//  matchmaker fields) with a "why was this flagged" panel on top and
//  Approve / Reject actions pinned below. Reject requires a canned reason
//  (plus an optional note, required for "Other").
//

import SwiftUI
import YentlShared

struct ApprovalsView: View {
    @Environment(MatchmakerService.self) private var matchmaker

    @State private var rows: [PendingReviewProfile] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Approvals")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        SignOutButton()
                    }
                }
                .navigationDestination(for: PendingReviewProfile.self) { entry in
                    ApprovalDetailView(entry: entry) { await load() }
                }
                .task { await load() }
                .refreshable { await load() }
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
            MatchListMessage(icon: "checkmark.shield",
                             title: "No profiles to review",
                             message: "Profiles the AI screening flags will wait here. "
                                    + "Clean profiles approve automatically.")
        } else {
            List(rows) { entry in
                NavigationLink(value: entry) { row(entry) }
            }
        }
    }

    private func row(_ entry: PendingReviewProfile) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Text(entry.age.map { "\(entry.displayName), \($0)" } ?? entry.displayName)
                    .font(DesignTokens.Typography.body)
                Spacer()
                Text(entry.flaggedAt, format: .relative(presentation: .named))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
            Text(flagSummaryLine(entry))
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.orange)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private func flagSummaryLine(_ entry: PendingReviewProfile) -> String {
        let summaries = entry.reasons.flagSummaries
        return summaries.isEmpty ? "Flagged (no AI reasons recorded)"
                                 : summaries.joined(separator: " · ")
    }

    private func load() async {
        errorMessage = nil
        defer { isLoading = false }
        do {
            // Also refreshes the tab badge (the service tracks the count).
            rows = try await matchmaker.pendingReviewProfiles()
        } catch is CancellationError {
            // Transient task cancellation (view re-identified during the
            // role-gate → tab transition) — a fresh load follows; don't show it.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Full profile (photos + hidden matchmaker fields, reusing `ProfileScreen`)
/// with the AI flag reasons pinned on top and Approve / Reject pinned below.
private struct ApprovalDetailView: View {
    @Environment(MatchmakerService.self) private var matchmaker
    @Environment(\.dismiss) private var dismiss

    let entry: PendingReviewProfile
    /// Runs after a successful decision, before popping — the list uses it to
    /// drop the decided profile and refresh the badge.
    let onDecision: () async -> Void

    @State private var isSubmitting = false
    @State private var confirmingApprove = false
    @State private var rejecting = false
    @State private var actionError: String?

    var body: some View {
        ProfileScreen(userID: entry.profileID, showHiddenFields: true)
            .navigationTitle(entry.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) { flagPanel }
            .safeAreaInset(edge: .bottom) { actionBar }
            .confirmationDialog(
                "Approve this profile?",
                isPresented: $confirmingApprove,
                titleVisibility: .visible
            ) {
                Button("Approve \(entry.displayName)") {
                    Task { await approve() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The profile goes live and joins the matchmaking queue.")
            }
            .sheet(isPresented: $rejecting) {
                RejectReasonSheet(displayName: entry.displayName) { reason, note in
                    await reject(reason: reason, note: note)
                }
            }
            .alert(
                "Couldn't submit the decision",
                isPresented: Binding(get: { actionError != nil },
                                     set: { if !$0 { actionError = nil } })
            ) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: {
                if let actionError { Text(actionError) }
            }
    }

    // MARK: - Why it was flagged

    private var flagPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Label("Flagged by AI screening", systemImage: "exclamationmark.shield")
                .font(DesignTokens.Typography.caption.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(flagLines, id: \.self) { line in
                HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                    Text("•")
                    Text(line)
                }
                .font(DesignTokens.Typography.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var flagLines: [String] {
        let lines = entry.reasons.detailLines
        return lines.isEmpty
            ? ["The AI recorded no readable reasons — review the profile manually."]
            : lines
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Button { rejecting = true } label: {
                Label("Reject", systemImage: "xmark.circle").frame(maxWidth: .infinity)
            }
            .tint(.red)
            Button { confirmingApprove = true } label: {
                Label("Approve", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
            }
            .tint(.green)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isSubmitting)
        .padding(DesignTokens.Spacing.md)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func approve() async {
        await submit { try await matchmaker.approveProfile(entry.profileID) }
    }

    private func reject(reason: ProfileRejectionReason, note: String) async {
        await submit {
            try await matchmaker.rejectProfile(entry.profileID,
                                               reason: reason.reasonText(note: note))
        }
    }

    /// Runs a decision RPC, then refreshes the list and pops back to it.
    private func submit(_ action: () async throws -> Void) async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await action()
            await onDecision()
            dismiss()
        } catch is CancellationError {
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// Canned rejection reason picker + optional note. The reason is mandatory;
/// the note is required only for "Other" (a bare "other" tells the rejected
/// user nothing).
private struct RejectReasonSheet: View {
    @Environment(\.dismiss) private var dismiss

    let displayName: String
    /// Called with the chosen reason + note; the sheet dismisses itself first
    /// so the detail view can pop cleanly after the RPC.
    let onReject: (ProfileRejectionReason, String) async -> Void

    @State private var reason: ProfileRejectionReason?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    ForEach(ProfileRejectionReason.allCases) { candidate in
                        Button {
                            reason = candidate
                        } label: {
                            HStack {
                                Text(candidate.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if reason == candidate {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(DesignTokens.Palette.primary)
                                }
                            }
                        }
                    }
                }
                Section {
                    TextField("Add context for \(displayName)…", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text(reason == .other ? "Note (required for Other)" : "Note (optional)")
                } footer: {
                    Text("The reason is stored on the audit trail and shown to the "
                       + "user with their rejected profile.")
                }
            }
            .navigationTitle("Reject profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reject", role: .destructive) {
                        guard let reason else { return }
                        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                        Task { await onReject(reason, trimmedNote) }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var canSubmit: Bool {
        guard let reason else { return false }
        if reason == .other {
            return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }
}
