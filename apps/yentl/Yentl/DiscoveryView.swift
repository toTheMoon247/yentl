//
//  DiscoveryView.swift
//  Yentl
//
//  The discovery stack: shows one live candidate at a time (public profile via
//  the shared PublicProfileCard) with Pass / Like actions. Swipes are recorded
//  but never surfaced back to the user. Slice 1 is a simple one-at-a-time card
//  with buttons; richer card/gesture and empty-state polish come in Slice 2.
//

import SwiftUI
import YentlShared

struct DiscoveryView: View {
    @Environment(DiscoveryService.self) private var discovery
    @Environment(ProfileService.self) private var profiles

    @State private var feed: [Profile] = []
    @State private var index = 0
    @State private var photoURLs: [URL] = []
    @State private var prompts: [ProfilePrompt] = []
    @State private var isLoading = true
    @State private var isActing = false
    @State private var errorMessage: String?

    private var current: Profile? {
        index < feed.count ? feed[index] : nil
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Discover")
        }
        .task { await loadFeed() }
        .task(id: current?.id) { await loadCandidateMedia() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
        } else if let errorMessage {
            messageState(
                icon: "exclamationmark.triangle",
                title: "Something went wrong",
                message: errorMessage,
                action: ("Try again", { Task { await loadFeed() } })
            )
        } else if let current {
            VStack(spacing: 0) {
                ScrollView {
                    PublicProfileCard(profile: current, photoURLs: photoURLs, prompts: prompts)
                }
                actionBar
            }
        } else {
            messageState(
                icon: "sparkles",
                title: "You've seen everyone",
                message: "Check back later for new people.",
                action: ("Refresh", { Task { await loadFeed() } })
            )
        }
    }

    private var actionBar: some View {
        HStack(spacing: DesignTokens.Spacing.xl) {
            actionButton(systemName: "xmark", tint: .secondary) {
                Task { await act(.pass) }
            }
            actionButton(systemName: "heart.fill", tint: .pink) {
                Task { await act(.like) }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.md)
        .disabled(isActing)
    }

    private func actionButton(systemName: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .background(.thinMaterial, in: Circle())
        }
    }

    private func messageState(
        icon: String,
        title: String,
        message: String,
        action: (String, () -> Void)
    ) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            Text(title).font(DesignTokens.Typography.titleMedium)
            Text(message)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button(action.0, action: action.1)
                .buttonStyle(.borderedProminent)
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Data

    private func loadFeed() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            feed = try await discovery.fetchFeed()
            index = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCandidateMedia() async {
        photoURLs = []
        prompts = []
        guard let current else { return }
        do {
            let photos = try await profiles.listPhotos(userID: current.id)
            var urls: [URL] = []
            for photo in photos {
                if let url = try? await profiles.signedPhotoURL(for: photo.storagePath) {
                    urls.append(url)
                }
            }
            photoURLs = urls
            prompts = try await profiles.listPrompts(userID: current.id)
        } catch {
            // Non-fatal: show the card without media rather than blocking.
            errorMessage = nil
        }
    }

    private func act(_ action: SwipeAction) async {
        guard let current else { return }
        isActing = true
        defer { isActing = false }
        do {
            try await discovery.recordSwipe(toUserID: current.id, action: action)
            index += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    DiscoveryView()
        .environment(DiscoveryService.shared)
        .environment(ProfileService.shared)
}
