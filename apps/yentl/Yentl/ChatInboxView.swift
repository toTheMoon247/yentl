//
//  ChatInboxView.swift
//  Yentl
//
//  Phase 7 Slice 2/3: the chat tab — the signed-in user's channels, split
//  into Active and Archived by the 48h-inactivity rule (ChatArchiveRule).
//
//  The split is pure view-state computed on render from each channel's
//  lastMessageAt (falling back to createdAt for never-messaged chats):
//  nothing is stored server-side and no channel is frozen. An archived chat
//  stays fully openable; sending in it moves it back to Active on its own,
//  because lastMessageAt advances. Channels themselves are created
//  server-side on match confirmation by the stream-channel Edge Function.
//
//  This is a custom list over ChatChannelListController (per the SwiftUI
//  SDK's custom-channel-list cookbook) rather than ChatChannelListView,
//  because the stock view renders exactly one undifferentiated list and the
//  archive rule needs two sections over one query.
//

import Combine
import StreamChat
import StreamChatSwiftUI
import SwiftUI
import YentlShared

struct ChatInboxView: View {
    @Environment(ChatService.self) private var chat

    var body: some View {
        switch chat.connectionState {
        case .connected(let userID):
            // `.id` rebuilds the list (fresh controller and query) when the
            // DEBUG picker switches accounts.
            InboxChannelList(userID: userID, client: chat.chatClient)
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

/// The user's messaging channels in two sections: Active, and a collapsed
/// Archived section for chats 48h+ quiet.
///
/// Phase 7 (block/report): the list is cross-checked against my_matches() and
/// shows only channels belonging to a CONFIRMED match. A blocked match leaves
/// my_matches() on both sides, so its channel disappears from each person's
/// inbox on their next visit — the app-side half of "blocking hides the chat".
/// (Server-side Stream channel freeze/delete is deferred; see the Phase 11
/// note in YentlShared/StreamChannelService.)
private struct InboxChannelList: View {
    @Injected(\.utils) private var utils

    private let client: ChatClient
    @StateObject private var model: InboxChannelsModel
    @State private var showArchived = false

    @Environment(MatchService.self) private var matchService
    /// Confirmed matches keyed by their Stream channel id
    /// (`match-<uuid, lowercased>`). Nil until the first load finishes.
    @State private var confirmedByChannelID: [String: MatchSummary]?

    init(userID: String, client: ChatClient) {
        self.client = client
        _model = StateObject(wrappedValue: InboxChannelsModel(client: client, userID: userID))
    }

    var body: some View {
        NavigationStack {
            // Re-evaluates the 48h split once a minute, so a chat crossing
            // the threshold moves sections without a reload.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let all = model.channels.filter { match(for: $0) != nil }
                let archived = all.filter { isArchived($0, now: context.date) }
                let active = all.filter { !isArchived($0, now: context.date) }

                Group {
                    if confirmedByChannelID == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if all.isEmpty {
                        emptyState
                    } else {
                        List {
                            if active.isEmpty {
                                Section {
                                    Text("No active conversations — everything is in Archived.")
                                        .font(DesignTokens.Typography.caption)
                                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                                }
                            } else {
                                Section {
                                    ForEach(active, id: \.cid) { row($0) }
                                }
                            }
                            if !archived.isEmpty {
                                Section {
                                    if showArchived {
                                        ForEach(archived, id: \.cid) { row($0) }
                                    }
                                } header: {
                                    archivedHeader(count: archived.count)
                                } footer: {
                                    if showArchived {
                                        Text("Quiet for 48 hours. Send a message to bring a chat back.")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Messages")
        }
        .onAppear { model.start() }
        .task { await loadMatches() }
    }

    /// The confirmed match backing a channel, or nil if the channel should be
    /// hidden (blocked / no longer confirmed / unknown id).
    private func match(for channel: ChatChannel) -> MatchSummary? {
        confirmedByChannelID?[channel.cid.id]
    }

    private func loadMatches() async {
        do {
            let matches = try await matchService.myMatches()
            confirmedByChannelID = Dictionary(
                uniqueKeysWithValues: matches
                    .filter { $0.state == .confirmed }
                    .map { ("match-\($0.matchID.uuidString.lowercased())", $0) }
            )
        } catch is CancellationError {
        } catch {
            // Without the match list we can't know which channels are safe to
            // show; treat a hard failure as "none" rather than risk surfacing
            // a blocked chat. (Transient — reloads on next tab visit.)
            if confirmedByChannelID == nil { confirmedByChannelID = [:] }
        }
    }

    private func isArchived(_ channel: ChatChannel, now: Date) -> Bool {
        ChatArchiveRule.isArchived(
            lastMessageAt: channel.lastMessageAt,
            createdAt: channel.createdAt,
            now: now
        )
    }

    @ViewBuilder
    private func row(_ channel: ChatChannel) -> some View {
        NavigationLink {
            // Through the Phase 9 pay gate (which wraps
            // MatchConversationView, not raw ChatChannelView) so both the
            // payment gate and the block/report menu hold from the inbox
            // too. The rows are pre-filtered to confirmed matches, so the
            // summary exists.
            if let summary = match(for: channel) {
                MatchChatGateView(match: summary, onBlocked: {
                    Task { await loadMatches() }
                })
                .navigationTitle(name(of: channel))
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ChatChannelView(channelController: client.channelController(for: channel.cid))
                    .navigationTitle(name(of: channel))
                    .navigationBarTitleDisplayMode(.inline)
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name(of: channel))
                        .font(DesignTokens.Typography.body)
                        .lineLimit(1)
                    Text(channel.latestMessages.first?.text ?? "No messages yet")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let last = channel.lastMessageAt {
                        Text(last, format: .relative(presentation: .named))
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Palette.textSecondary)
                    }
                    if channel.unreadCount.messages > 0 {
                        Text("\(channel.unreadCount.messages)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignTokens.Palette.primary, in: Capsule())
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func archivedHeader(count: Int) -> some View {
        Button {
            withAnimation { showArchived.toggle() }
        } label: {
            HStack {
                Label("Archived (\(count))", systemImage: "archivebox")
                Spacer()
                Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
        }
        .foregroundStyle(DesignTokens.Palette.textSecondary)
    }

    /// Row title: match chats are 1:1, so the other member's name IS the
    /// conversation's name. The SDK formatter is the fallback (it needs
    /// `channel.name`, which match channels don't set).
    private func name(of channel: ChatChannel) -> String {
        if let other = channel.lastActiveMembers.first(where: { $0.id != client.currentUserId }),
           let name = other.name, !name.isEmpty {
            return name
        }
        return utils.channelNameFormatter.format(
            channel: channel,
            forCurrentUserId: client.currentUserId
        ) ?? "Conversation"
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            Text("No conversations yet")
                .font(DesignTokens.Typography.titleMedium)
            Text("When a match is confirmed, your chat starts here.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Observes the user's messaging channels via ChatChannelListController.
/// (StreamChat v5 dropped the controllers' SwiftUI `observableObject`
/// wrappers, so this bridges the Combine publisher to `@Published`.)
@MainActor
private final class InboxChannelsModel: ObservableObject {
    @Published private(set) var channels: [ChatChannel] = []

    private let controller: ChatChannelListController
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    init(client: ChatClient, userID: String) {
        controller = client.channelListController(
            query: .init(
                filter: .and([
                    .equal(.type, to: .messaging),
                    .containMembers(userIds: [userID]),
                ]),
                sort: [
                    .init(key: .lastMessageAt, isAscending: false),
                    .init(key: .createdAt, isAscending: false),
                ]
            )
        )
    }

    /// Starts the query and change observation. Idempotent — safe on every
    /// `onAppear` of the inbox tab.
    func start() {
        guard !started else { return }
        started = true
        controller.channelsChangesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.channels = self.controller.channels
            }
            .store(in: &cancellables)
        controller.synchronize { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.channels = self.controller.channels
            }
        }
    }
}
