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
    @State private var mediaByID: [UUID: CandidateMedia] = [:]
    @State private var isLoading = true
    @State private var isActing = false
    @State private var showingDetail = false
    @State private var errorMessage: String?

    /// How many upcoming cards to prefetch so the next swipe feels instant.
    private let prefetchAhead = 2

    private var current: Profile? {
        index < feed.count ? feed[index] : nil
    }

    private var currentMedia: CandidateMedia? {
        current.flatMap { mediaByID[$0.id] }
    }

    /// A candidate's loaded photos (signed URLs) and prompts.
    struct CandidateMedia {
        var photoURLs: [URL]
        var prompts: [ProfilePrompt]
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
        .task(id: current?.id) { await loadCurrentAndPrefetch() }
        .sheet(isPresented: $showingDetail) {
            if let current {
                CandidateDetailView(
                    profile: current,
                    photoURLs: currentMedia?.photoURLs ?? [],
                    prompts: currentMedia?.prompts ?? [],
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
                    photoURL: currentMedia?.photoURLs.first,
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
        mediaByID = [:]
        defer { isLoading = false }
        do {
            feed = try await discovery.fetchFeed()
            index = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Load the current candidate's media (usually already prefetched, so
    /// instant), then prefetch the next few so upcoming swipes feel immediate.
    private func loadCurrentAndPrefetch() async {
        let start = index
        // Current first, so the visible card resolves ASAP (AsyncImage then
        // downloads its photo). Don't warm the current image here — that would
        // just duplicate AsyncImage's own download.
        await ensureMedia(at: start)
        // Upcoming cards: load their URLs AND warm the first image's bytes, so
        // when they become current the same signed URL is a cache hit.
        for offset in 1...prefetchAhead {
            let idx = start + offset
            await ensureMedia(at: idx)
            await warmFirstImage(at: idx)
        }
    }

    private func warmFirstImage(at idx: Int) async {
        guard idx >= 0, idx < feed.count,
              let url = mediaByID[feed[idx].id]?.photoURLs.first else { return }
        // Download AND decode into the in-memory cache, so the card shows it
        // with no network/decode work when reached.
        await ImageCache.shared.load(url)
    }

    /// Loads (and caches) photos + prompts for the candidate at `idx`, if not
    /// already cached. No-op when out of range or already loaded.
    private func ensureMedia(at idx: Int) async {
        guard idx >= 0, idx < feed.count else { return }
        let profile = feed[idx]
        guard mediaByID[profile.id] == nil else { return }

        var urls: [URL] = []
        if let photos = try? await profiles.listPhotos(userID: profile.id) {
            for photo in photos {
                if let url = try? await profiles.signedPhotoURL(for: photo.storagePath) {
                    urls.append(url)
                }
            }
        }
        let loadedPrompts = (try? await profiles.listPrompts(userID: profile.id)) ?? []
        mediaByID[profile.id] = CandidateMedia(photoURLs: urls, prompts: loadedPrompts)
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
