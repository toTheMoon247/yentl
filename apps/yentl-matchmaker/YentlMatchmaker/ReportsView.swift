//
//  ReportsView.swift
//  YentlMatchmaker
//
//  Phase 11 Slice 1: the reports moderation queue. Users can block/report from
//  a chat (Phase 7); this is where those reports land. Only OPEN reports appear
//  (`moderation_open_reports`), newest first, with the reporter → reported
//  names, the canned reason, and a repeat-offender count. The detail reuses the
//  full-profile viewer for the REPORTED user, with the report context pinned on
//  top and Dismiss / Suspend / Ban / Reinstate below. Suspending or banning
//  from a report marks it actioned; Dismiss closes it with no account change.
//

import SwiftUI
import YentlShared

struct ReportsView: View {
    @Environment(ModerationService.self) private var moderation

    @State private var rows: [ModerationReport] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Reports")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { SignOutButton() }
                }
                .navigationDestination(for: ModerationReport.self) { report in
                    ReportDetailView(report: report) { await load() }
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
            MatchListMessage(icon: "flag.slash",
                             title: "No open reports",
                             message: "Reports users file from a chat will wait here "
                                    + "for review.")
        } else {
            List(rows) { report in
                NavigationLink(value: report) { row(report) }
            }
        }
    }

    private func row(_ report: ModerationReport) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Text(reportedName(report))
                    .font(DesignTokens.Typography.body)
                Spacer()
                Text(report.createdAt, format: .relative(presentation: .named))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(report.reasonLabel)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.orange)
                if report.reportsAgainstReported > 1 {
                    Text("· \(report.reportsAgainstReported) reports")
                        .font(DesignTokens.Typography.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                if let kind = report.reportedStatusKind, kind != .active {
                    Text("· \(kind.rawValue)")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                }
            }
            Text("reported by \(report.reporterDisplayName ?? "someone")")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private func reportedName(_ report: ModerationReport) -> String {
        report.reportedDisplayName ?? "Unknown user"
    }

    private func load() async {
        errorMessage = nil
        defer { isLoading = false }
        do {
            rows = try await moderation.openReports()
        } catch is CancellationError {
            // Transient re-identification during the role-gate → tab transition.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The reported user's full profile with the report context pinned on top and
/// moderation actions below. Actions offered depend on the reported user's
/// LIVE status (re-fetched here), not the snapshot from the list.
private struct ReportDetailView: View {
    @Environment(ModerationService.self) private var moderation
    @Environment(\.dismiss) private var dismiss

    let report: ModerationReport
    /// Runs after any successful action, before popping — the list uses it to
    /// drop the report and refresh the badge.
    let onResolved: () async -> Void

    @State private var status: AccountStatusKind
    @State private var isSubmitting = false
    @State private var confirmingDismiss = false
    @State private var suspending = false
    @State private var banning = false
    @State private var confirmingReinstate = false
    @State private var actionError: String?

    init(report: ModerationReport, onResolved: @escaping () async -> Void) {
        self.report = report
        self.onResolved = onResolved
        _status = State(initialValue: report.reportedStatusKind ?? .active)
    }

    var body: some View {
        ProfileScreen(userID: report.reportedID, showHiddenFields: true)
            .navigationTitle(report.reportedDisplayName ?? "Reported user")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) { reportPanel }
            .safeAreaInset(edge: .bottom) { actionBar }
            .task { await refreshStatus() }
            .confirmationDialog("Dismiss this report?",
                                isPresented: $confirmingDismiss, titleVisibility: .visible) {
                Button("Dismiss — no action") { Task { await dismissReport() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Closes the report without changing the account.")
            }
            .confirmationDialog("Reinstate this account?",
                                isPresented: $confirmingReinstate, titleVisibility: .visible) {
                Button("Reinstate") { Task { await reinstate() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The account returns to active and can use the app again.")
            }
            .sheet(isPresented: $suspending) {
                ModerationReasonSheet(title: "Suspend account", isSuspension: true,
                                      reportedName: report.reportedDisplayName) { reason, until in
                    await suspend(reason: reason, until: until)
                }
            }
            .sheet(isPresented: $banning) {
                ModerationReasonSheet(title: "Ban account", isSuspension: false,
                                      reportedName: report.reportedDisplayName) { reason, _ in
                    await ban(reason: reason)
                }
            }
            .alert("Couldn't complete the action",
                   isPresented: Binding(get: { actionError != nil },
                                        set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: {
                if let actionError { Text(actionError) }
            }
    }

    // MARK: - Report context

    private var reportPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Label(report.reasonLabel, systemImage: "flag.fill")
                .font(DesignTokens.Typography.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if let note = report.note, !note.isEmpty {
                Text("\u{201C}\(note)\u{201D}")
                    .font(DesignTokens.Typography.caption)
                    .italic()
            }
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("reported by \(report.reporterDisplayName ?? "someone")")
                if report.reportsAgainstReported > 1 {
                    Text("· \(report.reportsAgainstReported) total reports")
                        .foregroundStyle(.red)
                }
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Palette.textSecondary)
            if status != .active {
                Text("Currently \(status.rawValue)")
                    .font(DesignTokens.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Actions (depend on live status)

    private var actionBar: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Button { confirmingDismiss = true } label: {
                Label("Dismiss", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
            }
            if status == .active {
                Button { suspending = true } label: {
                    Label("Suspend", systemImage: "clock.badge.xmark").frame(maxWidth: .infinity)
                }
                .tint(.orange)
                Button { banning = true } label: {
                    Label("Ban", systemImage: "nosign").frame(maxWidth: .infinity)
                }
                .tint(.red)
            } else {
                if status == .suspended {
                    Button { banning = true } label: {
                        Label("Ban", systemImage: "nosign").frame(maxWidth: .infinity)
                    }
                    .tint(.red)
                }
                Button { confirmingReinstate = true } label: {
                    Label("Reinstate", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
                .tint(.green)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isSubmitting)
        .padding(DesignTokens.Spacing.md)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func refreshStatus() async {
        if let live = try? await moderation.fetchAccountStatus(of: report.reportedID) {
            status = live.kind
        }
    }

    private func dismissReport() async {
        await submit { try await moderation.resolveReport(id: report.reportID, dismiss: true) }
    }

    private func suspend(reason: String, until: Date) async {
        await submit {
            try await moderation.suspend(target: report.reportedID, until: until,
                                         reason: reason, reportId: report.reportID)
        }
    }

    private func ban(reason: String) async {
        await submit {
            try await moderation.ban(target: report.reportedID, reason: reason,
                                     reportId: report.reportID)
        }
    }

    private func reinstate() async {
        await submit { try await moderation.reinstate(target: report.reportedID) }
    }

    /// Runs a moderation RPC, refreshes the list, and pops back to it.
    private func submit(_ action: () async throws -> Void) async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await action()
            await onResolved()
            dismiss()
        } catch is CancellationError {
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// Reason entry for suspend/ban. A reason is mandatory (it's stored on the
/// audit trail). Suspension also picks a duration; ban does not.
private struct ModerationReasonSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let isSuspension: Bool
    let reportedName: String?
    /// Reason + the suspension end (ignored for a ban). The sheet dismisses
    /// itself first so the detail view can pop cleanly after the RPC.
    let onSubmit: (String, Date) async -> Void

    @State private var reason = ""
    @State private var duration: SuspensionDuration = .week

    var body: some View {
        NavigationStack {
            Form {
                if isSuspension {
                    Section("Duration") {
                        Picker("For", selection: $duration) {
                            ForEach(SuspensionDuration.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section {
                    TextField("Reason", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Reason (required)")
                } footer: {
                    Text("Stored on the moderation audit trail"
                       + (isSuspension ? " and shown to the user while suspended." : "."))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSuspension ? "Suspend" : "Ban", role: .destructive) {
                        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        let until = duration.until()
                        dismiss()
                        Task { await onSubmit(trimmed, until) }
                    }
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
