//
//  NotificationSettingsView.swift
//  Yentl
//
//  Phase 8 (Slice 3): the consumer app's notification preferences, reached
//  from the Profile tab. Two toggles, both defaulting to ON (no stored row
//  means opted in):
//
//    - Match notifications → notification_preferences.match_pushes, enforced
//      server-side by the `notify` Edge Function before it targets anyone.
//    - Message notifications → message_pushes, enforced client-side: the
//      toggle also registers/removes this device with Stream, because chat
//      pushes come straight from Stream and never pass through our backend.
//
//  Every write is persisted immediately on toggle. Best-effort by design: a
//  failed save shows a notice and rolls the toggle back to the stored value —
//  the screen never crashes and never lies about what is saved.
//

import SwiftUI
import YentlShared

struct NotificationSettingsView: View {
    @Environment(ChatService.self) private var chat

    @State private var matchPushes = true
    @State private var messagePushes = true
    /// True once the stored preferences have loaded — toggle changes before
    /// that are the load itself, not the user, and must not write back.
    @State private var isLoaded = false
    @State private var loadFailed = false
    @State private var saveError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Match notifications", isOn: $matchPushes)
                    .disabled(!isLoaded)
            } footer: {
                Text("A push when your matchmaker introduces you to someone new, and when a match becomes mutual.")
            }

            Section {
                Toggle("Message notifications", isOn: $messagePushes)
                    .disabled(!isLoaded)
            } footer: {
                Text("A push when a match sends you a chat message.")
            }

            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.orange)
                }
            }

            if loadFailed {
                Section {
                    Button("Try again") { Task { await load() } }
                } footer: {
                    Text("Couldn't load your notification settings.")
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: matchPushes) { _, _ in
            guard isLoaded else { return }
            Task { await save(messageToggleChanged: false) }
        }
        .onChange(of: messagePushes) { _, _ in
            guard isLoaded else { return }
            Task { await save(messageToggleChanged: true) }
        }
    }

    private func load() async {
        loadFailed = false
        do {
            let prefs = try await NotificationPreferencesService.shared.fetch()
            // isLoaded gates the onChange handlers, so setting the state here
            // does not trigger a write-back.
            isLoaded = false
            matchPushes = prefs.matchPushes
            messagePushes = prefs.messagePushes
            // Let the onChange from the assignments (if any) fire before
            // arming the handlers.
            await Task.yield()
            isLoaded = true
        } catch {
            loadFailed = true
        }
    }

    private func save(messageToggleChanged: Bool) async {
        saveError = nil
        let desired = NotificationPreferences(
            matchPushes: matchPushes, messagePushes: messagePushes
        )
        do {
            try await NotificationPreferencesService.shared.update(desired)
            if messageToggleChanged {
                // Persisted first, then enforced: ChatService re-reads the
                // (now cached) preference before re-registering.
                await chat.messagePushPreferenceChanged(enabled: desired.messagePushes)
            }
        } catch {
            saveError = "Couldn't save that change. Check your connection and try again."
            // Roll back to what the server actually has.
            let stored = NotificationPreferencesService.shared.cached ?? .defaults
            isLoaded = false
            matchPushes = stored.matchPushes
            messagePushes = stored.messagePushes
            await Task.yield()
            isLoaded = true
        }
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView()
    }
    .environment(ChatService.shared)
}
