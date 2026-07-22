//
//  BlockReportSheet.swift
//  Yentl
//
//  Phase 7: block / report from a match or its chat.
//
//  BLOCK ends the match for both people (terminal `blocked` state server-side;
//  each side's next refresh simply no longer contains it) and records a
//  do-not-pair-again flag matchmakers will see. A reason is optional — picking
//  one files a report in the same call. REPORT only files a report; the match
//  continues. The matchmaker-side moderation queue is Phase 11.
//

import SwiftUI
import YentlShared

/// What the sheet does on submit.
enum BlockReportMode: Identifiable {
    case block
    case report

    var id: Self { self }
}

/// Toolbar entry point for the safety actions, shown on a match's detail and
/// inside its conversation.
struct SafetyMenu: View {
    let onReport: () -> Void
    let onBlock: () -> Void

    var body: some View {
        Menu {
            Button {
                onReport()
            } label: {
                Label("Report…", systemImage: "flag")
            }
            Button(role: .destructive) {
                onBlock()
            } label: {
                Label("Block…", systemImage: "hand.raised")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Safety options")
        }
    }
}

/// The block / report form: canned reason picker + optional note.
struct BlockReportSheet: View {
    let mode: BlockReportMode
    let match: MatchSummary
    /// Called after a successful submit. `endedMatch` is true when the match
    /// was blocked — the presenter should leave the conversation and refresh.
    let onDone: (_ endedMatch: Bool) -> Void

    @Environment(MatchService.self) private var matchService
    @Environment(\.dismiss) private var dismiss

    @State private var reason: ReportReason?
    @State private var note = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var name: String { match.otherDisplayName }

    private var canSubmit: Bool {
        // A report needs a reason; a block stands on its own.
        !isSubmitting && (mode == .block || reason != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(explainer)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                }

                Section(reasonHeader) {
                    ForEach(ReportReason.allCases) { candidate in
                        Button {
                            // Tapping the selected reason again clears it —
                            // relevant for block, where the reason is optional.
                            reason = (reason == candidate) ? nil : candidate
                        } label: {
                            HStack {
                                Text(candidate.label)
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

                Section("Details (optional)") {
                    TextField("Anything the matchmakers should know?",
                              text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: mode == .block ? .destructive : nil) {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text(mode == .block ? "Block \(name)" : "Send report")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle(mode == .block ? "Block \(name)" : "Report \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private var explainer: String {
        switch mode {
        case .block:
            return "Blocking ends this match for both of you and hides the "
                 + "conversation. \(name) won't be told you blocked them, and "
                 + "your matchmaker will see the flag. Adding a reason also "
                 + "files a report."
        case .report:
            return "Your report goes to the Yentl matchmakers, never to "
                 + "\(name). Reporting doesn't end the match — use Block for "
                 + "that."
        }
    }

    private var reasonHeader: String {
        mode == .block ? "Also report — optional" : "Reason"
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            switch mode {
            case .block:
                try await matchService.blockMatch(
                    matchID: match.matchID, reason: reason, note: note
                )
                dismiss()
                onDone(true)
            case .report:
                guard let reason else { return }
                try await matchService.reportUser(
                    userID: match.otherID, reason: reason,
                    matchID: match.matchID, note: note
                )
                dismiss()
                onDone(false)
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
