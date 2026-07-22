//
//  ChatService.swift
//  Yentl
//
//  Phase 7 Slice 2: the consumer app's chat layer over Stream Chat.
//
//  One shared ChatClient for the whole app, connected with the signed-in
//  user's Supabase identity. Tokens come from the `stream-token` Edge
//  Function via ChatTokenService — the Stream API *secret* never ships in
//  the client, so this is the only way to get a token.
//

import Foundation
import Observation
import OSLog
import StreamChat
import StreamChatSwiftUI
import YentlShared

@MainActor
@Observable
final class ChatService {
    static let shared = ChatService()

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(userID: String)
        case failed(String)
    }

    private(set) var connectionState: ConnectionState = .disconnected

    /// The app's single Stream client.
    let chatClient: ChatClient

    /// Keeping the `StreamChat` instance alive registers `chatClient` with
    /// the StreamChatSwiftUI injection system all of its views read from.
    private let streamChat: StreamChat

    /// Last requested identity, so a failed connect can be retried from the UI.
    private var lastUserID: String?
    private var lastDisplayName: String?

    private init() {
        let config = ChatClientConfig(apiKey: APIKey(AppEnvironment.current.streamChatAPIKey))
        let client = ChatClient(config: config)
        chatClient = client
        streamChat = StreamChat(chatClient: client)
    }

    /// Connects the signed-in user to Stream.
    ///
    /// `userID` must be the Supabase auth UUID in **lowercase** — that is the
    /// exact string the `stream-token` function puts in the token's `user_id`
    /// claim, and Stream rejects a connect whose user id differs from it.
    func connect(userID: String, displayName: String?) async {
        if case .connected(let current) = connectionState, current == userID { return }

        // Note: no early-return while `.connecting` — a newer call (account
        // switch via the DEBUG picker) must supersede an in-flight one, or the
        // second account never connects. `lastUserID` marks the newest intent;
        // stale attempts check it before touching state.
        lastUserID = userID
        lastDisplayName = displayName
        connectionState = .connecting

        // Tear down any previous session first — Stream persists the last
        // user locally, so this matters even on a fresh launch.
        if let current = chatClient.currentUserId, current != userID {
            await chatClient.logout()
        }
        guard lastUserID == userID else { return } // superseded while logging out

        do {
            try await chatClient.connectUser(
                userInfo: UserInfo(id: userID, name: displayName),
                tokenProvider: { completion in
                    // Called for the initial connection and again whenever the
                    // current token expires (tokens live 1h) — the SDK refreshes
                    // transparently through this closure.
                    Task { @MainActor in
                        do {
                            let response = try await ChatTokenService.shared.fetchStreamToken()
                            completion(.success(try Token(rawValue: response.token)))
                        } catch {
                            ChatService.logger.error("Stream token fetch failed: \(String(describing: error))")
                            completion(.failure(error))
                        }
                    }
                }
            )
            guard lastUserID == userID else { return } // superseded mid-connect
            connectionState = .connected(userID: userID)
        } catch {
            ChatService.logger.error("Stream connect failed for \(userID): \(String(describing: error))")
            guard lastUserID == userID else { return }
            connectionState = .failed(error.localizedDescription)
        }
    }

    private static let logger = Logger(subsystem: "com.yentl.app", category: "chat")

    /// Retries the last failed connect (no-op unless `connect` ran before).
    func retryConnect() async {
        guard let lastUserID else { return }
        if case .failed = connectionState { connectionState = .disconnected }
        await connect(userID: lastUserID, displayName: lastDisplayName)
    }

    /// Disconnects and wipes local chat data — called on sign-out, and on
    /// account switch before reconnecting as someone else.
    func disconnect() async {
        lastUserID = nil
        lastDisplayName = nil
        guard chatClient.currentUserId != nil else {
            connectionState = .disconnected
            return
        }
        await chatClient.logout()
        connectionState = .disconnected
    }
}
