//
//  DiscoveryView.swift
//  Yentl
//
//  The discovery stack: shows one live candidate at a time as a draggable
//  SwipeCard (drag or use the buttons to like/pass; tap to open full detail).
//  Swipes are recorded but never surfaced back to the user.
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
    @State private var showingDetail = false
    @State private var errorMessage: String?

    private var current: Profile? {
        index < feed.count ? feed[index] : nil
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Discover")
                .toolbar {
                    #if DEBUG
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Reset swipes") { Task { await resetSwipes() } }
                            .disabled(isActing)
                    }
                    #endif
                }
        }
        .task { await loadFeed() }
        .task(id: current?.id) { await loadCandidateMedia() }
        .sheet(isPresented: $showingDetail) {
            if let current {
                CandidateDetailView(
                    profile: current,
                    photoURLs: photoURLs,
                    prompts: prompts,
                    onAction: { action in
                        showingDetail = false
                        Task { await act(action) }
                    }
                )
            }
        }
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
            VStack(spacing: DesignTokens.Spacing.md) {
                SwipeCard(
                    profile: current,
                    photoURL: photoURLs.first,
                    onSwipe: { action in Task { await act(action) } },
                    onTap: { showingDetail = true }
                )
                .id(current.id)
                .padding(.horizontal, DesignTokens.Spacing.md)

                actionBar
            }
            .padding(.bottom, DesignTokens.Spacing.md)
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
            CircleActionButton(systemName: "xmark", tint: .secondary) {
                Task { await act(.pass) }
            }
            CircleActionButton(systemName: "heart.fill", tint: .pink) {
                Task { await act(.like) }
            }
        }
        .disabled(isActing)
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

    #if DEBUG
    private func resetSwipes() async {
        errorMessage = nil
        do {
            try await discovery.clearMySwipes()
            await loadFeed()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

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

/// Full profile detail shown when a discovery card is tapped, with the same
/// like/pass actions at the bottom.
private struct CandidateDetailView: View {
    let profile: Profile
    let photoURLs: [URL]
    let prompts: [ProfilePrompt]
    let onAction: (SwipeAction) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    PublicProfileCard(profile: profile, photoURLs: photoURLs, prompts: prompts)
                }
                HStack(spacing: DesignTokens.Spacing.xl) {
                    CircleActionButton(systemName: "xmark", tint: .secondary) {
                        onAction(.pass)
                    }
                    CircleActionButton(systemName: "heart.fill", tint: .pink) {
                        onAction(.like)
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.md)
            }
            .navigationTitle(profile.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct CircleActionButton: View {
    let systemName: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .background(.thinMaterial, in: Circle())
        }
    }
}

#Preview {
    DiscoveryView()
        .environment(DiscoveryService.shared)
        .environment(ProfileService.shared)
}
