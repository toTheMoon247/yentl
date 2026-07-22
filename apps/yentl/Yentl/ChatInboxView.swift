//
//  ChatInboxView.swift
//  Yentl
//
//  Phase 7 Slice 2: the chat tab — Stream's channel list for the signed-in
//  user.
//
//  Shows every messaging channel the user is a member of. For now channels
//  are created client-side the first time a confirmed match opens its
//  conversation (see MatchConversationView); server-side creation on match
//  confirmation is Slice 3. The 48h-inactivity archive rule is also Slice 3:
//  it will become a section/filter over this same channel list rather than a
//  different screen, so nothing here assumes a channel stays visible forever.
//

import StreamChatSwiftUI
import SwiftUI
import YentlShared

struct ChatInboxView: View {
    @Environment(ChatService.self) private var chat

    var body: some View {
        switch chat.connectionState {
        case .connected(let userID):
            // ChatChannelListView embeds its own navigation stack and, with no
            // explicit controller, queries the channels containing the current
            // user. `.id` rebuilds it when the DEBUG picker switches accounts.
            ChatChannelListView(title: "Messages")
                .id(userID)
        case .connecting, .disconnected:
            ProgressView("Connecting to chat…")
        case .failed(let message):
            VStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
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
        }
    }
}
