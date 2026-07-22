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

    // MARK: Stream chat-message push (Phase 8)

    /// Name of the APN push provider configured in Stream's dashboard
    /// (token/.p8 auth, topic com.yentl.app). Device registrations must cite
    /// it by name or Stream will not know which credentials to send with.
    private static let streamPushProviderName = "yentl-ios"

    /// Raw APNs token from `AppDelegate`. Cached for the app's lifetime: it is
    /// per-device, not per-user, so it survives sign-out and account switches.
    private var apnsDeviceToken: Data?

    /// Stream device id (hex of the token) registered for the *current* user,
    /// nil when nothing is registered. Cleared on logout so the next account
    /// re-registers the same physical device under its own identity.
    private var registeredPushDeviceID: String?

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
            await removePushDevice() // stop the old user's chat pushes on this device
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
            registerPushDeviceIfReady()
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
        // Deregister the device *before* logout — removeDevice needs the
        // still-connected session, and a signed-out phone must stop getting
        // this user's chat pushes.
        await removePushDevice()
        await chatClient.logout()
        connectionState = .disconnected
    }

    // MARK: - Stream chat-message push (Phase 8)
    //
    // A new chat message triggers a push from Stream itself (no Edge Function
    // in the path): Stream sends to every device the recipient registered
    // against the `yentl-ios` APN provider configured in its dashboard.
    // OneSignal keeps handling match-lifecycle pushes; both SDKs share the one
    // APNs token, captured by `AppDelegate` and forwarded here.
    //
    // Everything below is best-effort by design: a failed registration or
    // removal is logged and swallowed — chat itself must keep working.
    //
    // Phase 8 (device test): APNs does not deliver to the simulator, so
    // end-to-end delivery AND coexistence with OneSignal (a Stream push
    // displaying while OneSignal's NSE is installed, and vice versa) can only
    // be verified on a physical device once the Apple Developer account is
    // active. Do not consider this slice proven until that test runs.
    //
    // Fallback: if on-device testing shows the two push paths cannot coexist,
    // the alternative is to drop Stream-native push and route chat-message
    // notifications through OneSignal instead, via a Stream `message.new`
    // webhook (Edge Function → OneSignal REST API). Deliberately not built
    // here — flag it rather than building both.

    /// Called by `AppDelegate` whenever APNs (re)issues this device's token.
    /// The token may arrive before or after the Stream user connects, in any
    /// order — registration happens once both halves are present.
    func apnsDeviceTokenReceived(_ token: Data) {
        apnsDeviceToken = token
        registeredPushDeviceID = nil // token rotated ⇒ any prior registration is stale
        registerPushDeviceIfReady()
    }

    /// Registers this device for the connected user's chat pushes, once both
    /// the APNs token and a connected Stream session exist. Safe to call any
    /// number of times; re-registration of the same token is skipped.
    private func registerPushDeviceIfReady() {
        guard case .connected = connectionState else {
            if apnsDeviceToken != nil {
                Self.logger.debug("Stream push: APNs token cached; will register device once Stream connects")
            }
            return
        }
        guard let token = apnsDeviceToken else {
            // Normal on the simulator, which never gets a real APNs token.
            Self.logger.debug("Stream push: connected; would register device with provider \(Self.streamPushProviderName) once an APNs token arrives")
            return
        }
        let deviceID = Self.deviceID(fromToken: token)
        guard registeredPushDeviceID != deviceID else { return }

        Self.logger.info("Stream push: registering device with provider \(Self.streamPushProviderName)")
        chatClient.currentUserController().addDevice(
            .apn(token: token, providerName: Self.streamPushProviderName)
        ) { [weak self] error in
            if let error {
                ChatService.logger.error("Stream push: device registration failed: \(String(describing: error))")
            } else {
                self?.registeredPushDeviceID = deviceID
                ChatService.logger.info("Stream push: device registered")
            }
        }
    }

    /// Removes this device from the current Stream user (best-effort). Must
    /// run while the user is still connected; callers invoke it before
    /// `chatClient.logout()`.
    private func removePushDevice() async {
        guard let deviceID = registeredPushDeviceID else { return }
        registeredPushDeviceID = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            chatClient.currentUserController().removeDevice(id: deviceID) { error in
                if let error {
                    // Swallowed: sign-out must never be blocked by push cleanup.
                    ChatService.logger.warning("Stream push: device removal failed: \(String(describing: error))")
                } else {
                    ChatService.logger.info("Stream push: device removed")
                }
                continuation.resume()
            }
        }
    }

    /// Stream identifies an APNs device by the lowercase-hex form of its
    /// token (the SDK's own `Data.deviceId` mapping, which is internal).
    private static func deviceID(fromToken token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
