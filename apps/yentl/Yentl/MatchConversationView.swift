//
//  MatchConversationView.swift
//  Yentl
//
//  Phase 7 Slice 2: the conversation for a confirmed match — Stream's
//  message list + composer.
//
//  Channel identity: one channel per match, id `match-<match UUID>`, so both
//  people land in the same channel no matter who opens it first.
//

import StreamChat
import StreamChatSwiftUI
import SwiftUI
import YentlShared

struct MatchConversationView: View {
    let match: MatchSummary

    @Environment(ChatService.self) private var chat
    @State private var controller: ChatChannelController?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let controller {
                ChatChannelView(channelController: controller)
            } else if let errorMessage {
                VStack(spacing: DesignTokens.Spacing.md) {
                    Image(systemName: "exclamationmark.bubble")
                        .font(.system(size: 44))
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                    Text("Couldn't open the chat")
                        .font(DesignTokens.Typography.titleMedium)
                    Text(errorMessage)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        self.errorMessage = nil
                        Task { await openChannel() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(DesignTokens.Spacing.xl)
            } else if case .failed(let message) = chat.connectionState {
                VStack(spacing: DesignTokens.Spacing.md) {
                    Text("Chat is unavailable")
                        .font(DesignTokens.Typography.titleMedium)
                    Text(message)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        Task { await chat.retryConnect() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(DesignTokens.Spacing.xl)
            } else {
                // Wait for the Stream connection before touching the channel —
                // opening a controller on an unconnected client fails.
                ProgressView("Opening chat…")
                    .task(id: chat.connectionState) {
                        guard case .connected = chat.connectionState else { return }
                        await openChannel()
                    }
            }
        }
    }

    /// Stream channel id for this match. Lowercased throughout: Stream ids
    /// are the lowercase Supabase UUIDs (see the stream-token Edge Function).
    private var channelID: ChannelId {
        ChannelId(type: .messaging, id: "match-\(match.matchID.uuidString.lowercased())")
    }

    private func openChannel() async {
        do {
            // Slice 3: channel creation is server-side. The stream-channel
            // Edge Function verifies (from the JWT) that the caller is a
            // participant of this confirmed match, upserts both Stream users
            // — the thing a client could never do for a partner who has not
            // connected yet — and creates-or-ensures `messaging:match-<id>`.
            // It is idempotent, so ensuring on every open is safe; a repeat
            // call is a session-cached no-op (StreamChannelService).
            try await StreamChannelService.shared.ensureMatchChannel(matchID: match.matchID)
            let controller = chat.chatClient.channelController(for: channelID)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                controller.synchronize { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            self.controller = controller
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
