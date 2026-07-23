//
//  MatchChatGateView.swift
//  Yentl
//
//  Phase 9: the "pay to unlock chat" gate. A confirmed match's conversation
//  opens only once BOTH participants have paid their own unlock fee — until
//  then this view shows the "Unlock your match" pay screen (or the "waiting
//  for them" state once the current user has paid). See docs/monetization-model.md.
//
//  Every path to a conversation goes through this gate: MatchDetailView's
//  "Open chat" button and the ChatInboxView rows both present it instead of
//  MatchConversationView directly. Payment state is re-checked on every
//  appearance and after every purchase; while waiting for the partner it
//  also polls, so the unlock happens without a manual refresh.
//

import RevenueCat
import SwiftUI
import YentlShared

struct MatchChatGateView: View {
    let match: MatchSummary
    /// Forwarded to MatchConversationView once unlocked.
    var onBlocked: () -> Void = {}

    private enum GateState: Equatable {
        /// First payment check in flight.
        case checking
        /// Both paid — show the conversation.
        case unlocked
        /// Not fully paid; `youPaid` picks the buy vs. waiting variant.
        case locked(youPaid: Bool)
        /// The payment check itself failed (network) — retry, never a dead end.
        case checkFailed(String)
    }

    @State private var state: GateState = .checking

    var body: some View {
        Group {
            switch state {
            case .unlocked:
                MatchConversationView(match: match, onBlocked: onBlocked)
            case .checking:
                ProgressView("Checking your match…")
            case .locked(let youPaid):
                PayToUnlockChatView(
                    match: match,
                    youPaid: youPaid,
                    onUnlocked: { state = .unlocked },
                    onYouPaid: { state = .locked(youPaid: true) },
                    refresh: { await refresh() }
                )
            case .checkFailed(let message):
                VStack(spacing: DesignTokens.Spacing.md) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 44))
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                    Text("Couldn't check your match")
                        .font(DesignTokens.Typography.titleMedium)
                    Text(message)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        state = .checking
                        Task { await refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(DesignTokens.Spacing.xl)
            }
        }
        .task { await refresh() }
    }

    /// Re-derives the gate state from the backend. Once unlocked, stays
    /// unlocked for this presentation — a transient failure on re-appear
    /// must not slam the door on an already-open conversation.
    private func refresh() async {
        if state == .unlocked { return }
        do {
            if try await PaymentService.shared.isMatchPaid(matchID: match.matchID) {
                state = .unlocked
                return
            }
            let youPaid = try await PaymentService.shared
                .hasCurrentUserPaid(matchID: match.matchID)
            state = .locked(youPaid: youPaid)
        } catch is CancellationError {
        } catch {
            if case .checking = state {
                state = .checkFailed(error.localizedDescription)
            }
            // Already showing a meaningful state (locked): keep it rather
            // than replacing the pay screen with an error.
        }
    }
}

/// The "Unlock your match" pay screen — the locked half of the gate.
private struct PayToUnlockChatView: View {
    let match: MatchSummary
    let youPaid: Bool
    let onUnlocked: () -> Void
    let onYouPaid: () -> Void
    /// Re-checks payment state upstream (used by the waiting poll).
    let refresh: () async -> Void

    @State private var price: String?
    @State private var isPurchasing = false
    @State private var notice: String?
    /// A completed purchase record-payment couldn't verify yet (e.g. the
    /// backend secret missing, or offline) — retried without re-charging.
    @State private var unverifiedTransactionID: String?

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()
            Image(systemName: youPaid ? "hourglass" : "lock.open.fill")
                .font(.system(size: 56))
                .foregroundStyle(DesignTokens.Palette.primary)
            Text(youPaid ? "You're in!" : "Unlock your match")
                .font(DesignTokens.Typography.titleLarge)
            explainer
            if let notice {
                Text(notice)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            actionArea
        }
        .padding(DesignTokens.Spacing.xl)
        .task { await loadPrice() }
        // While waiting for the partner, poll so the chat opens on its own
        // the moment they pay. Cancelled automatically on disappear.
        .task(id: youPaid) {
            guard youPaid else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await refresh()
            }
        }
    }

    @ViewBuilder
    private var explainer: some View {
        if youPaid {
            Text("You're paid. As soon as \(match.otherDisplayName) unlocks too, your chat opens.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
        } else {
            Text("""
                You and \(match.otherDisplayName) both said yes! To open your conversation, \
                each of you unlocks the match with a one-time fee\(price.map { " of \($0)" } ?? ""). \
                You only pay for matches you both want.
                """)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        if youPaid {
            Button {
                Task { await refresh() }
            } label: {
                Label("Check again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else if unverifiedTransactionID != nil {
            Button {
                Task { await retryVerification() }
            } label: {
                Label("Retry verification", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isPurchasing)
        } else {
            Button {
                Task { await buy() }
            } label: {
                Group {
                    if isPurchasing {
                        ProgressView()
                    } else {
                        Label(price.map { "Confirm for \($0)" } ?? "Confirm date",
                              systemImage: "heart.circle.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .controlSize(.large)
            .disabled(isPurchasing)
            .accessibilityIdentifier("confirm-date-buy")
        }
    }

    private func loadPrice() async {
        guard price == nil else { return }
        if let package = try? await PurchaseService.dateFeePackage() {
            price = PurchaseService.localizedPrice(of: package)
        }
        // Price stays nil on failure: the buy button still works (it
        // re-fetches the package) and shows a generic label.
    }

    private func buy() async {
        isPurchasing = true
        notice = nil
        defer { isPurchasing = false }

        let package: Package
        do {
            package = try await PurchaseService.dateFeePackage()
        } catch {
            notice = error.localizedDescription
            return
        }
        price = PurchaseService.localizedPrice(of: package)

        switch await PurchaseService.purchaseDateFee(package: package, matchID: match.matchID) {
        case .recorded(let matchPaid):
            matchPaid ? onUnlocked() : onYouPaid()
        case .cancelled:
            break // The user changed their mind — no message needed.
        case .pending:
            notice = "Your purchase is awaiting approval. The date confirms automatically once it completes."
        case .purchasedButNotRecorded(let message, let transactionID):
            unverifiedTransactionID = transactionID
            notice = "Your purchase went through, but we couldn't verify it yet: \(message)"
        case .failed(let message):
            notice = message
        }
    }

    /// Retries record-payment for an already-completed purchase — idempotent
    /// on the store transaction id, so this can never double-charge.
    private func retryVerification() async {
        guard let transactionID = unverifiedTransactionID else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let response = try await PaymentService.shared.recordPayment(
                matchID: match.matchID, storeTransactionID: transactionID
            )
            notice = nil
            unverifiedTransactionID = nil
            response.matchPaid ? onUnlocked() : onYouPaid()
        } catch {
            notice = "Still couldn't verify the purchase: \(error.localizedDescription)"
        }
    }
}
