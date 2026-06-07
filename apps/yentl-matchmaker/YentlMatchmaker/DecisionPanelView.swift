//
//  DecisionPanelView.swift
//  YentlMatchmaker
//
//  The core matchmaker UX. A photo card for the pinned (front-of-queue) user,
//  Match / Boost actions, and a swipeable carousel of their mutual-like
//  candidates (people who liked them AND whom they liked). Skip advances the
//  queue. With no candidates, a diagnostic (likes received vs given) steers
//  toward Boost (Phase 10) or Skip.
//
//  Match creation is Phase 6 and Boost is Phase 10 — both buttons are shown but
//  not yet wired. Tapping a card opens the full profile (with hidden fields).
//

import SwiftUI
import YentlShared

struct DecisionPanelView: View {
    @Environment(MatchmakerService.self) private var matchmaker
    @Environment(ProfileService.self) private var profiles
    @Environment(MatchService.self) private var matches

    /// When non-nil (opened by tapping a Queue row), the first load pins this
    /// specific user instead of the front of the queue. Consumed after one load,
    /// so Match / Next profile then continue with the normal queue.
    private let isRoot: Bool
    @State private var pendingOverride: UUID?

    /// Root (Review tab) panel: pins the front of the queue.
    init() {
        self.isRoot = true
        _pendingOverride = State(initialValue: nil)
    }

    /// Jump-to-pin: opened from the Queue tab to review a specific user.
    init(pinnedUserID: UUID) {
        self.isRoot = false
        _pendingOverride = State(initialValue: pinnedUserID)
    }

    @State private var isMatching = false
    @State private var confirmingMatch = false
    @State private var pinnedID: UUID?
    @State private var pinned: Profile?
    @State private var candidates: [Profile] = []
    @State private var candidateIndex = 0
    @State private var photoURLs: [UUID: URL] = [:]
    @State private var stats: LikeStats?
    @State private var isLoading = true
    @State private var isAdvancing = false
    @State private var errorMessage: String?
    @State private var phaseNote: String?
    @State private var inspected: Profile?

    var body: some View {
        if isRoot {
            NavigationStack { panel }
        } else {
            panel
        }
    }

    private var panel: some View {
        content
            .navigationTitle(isRoot ? "" : "Decision Panel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await load() }
            .sheet(item: $inspected) { profile in
                NavigationStack {
                    ProfileScreen(userID: profile.id, showHiddenFields: true)
                        .navigationTitle(profile.displayName)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Close") { inspected = nil }
                            }
                        }
                }
            }
            .confirmationDialog(
                "Create match?",
                isPresented: $confirmingMatch,
                titleVisibility: .visible
            ) {
                if let pinned, let candidate = currentCandidate {
                    Button("Match \(pinned.displayName) with \(candidate.displayName)") {
                        Task { await createMatch() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Both will be asked to confirm within 24 hours.")
            }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The account menu + "Review" title belong to the root tab only; the
        // pushed (jump-to-pin) panel gets the navigation back button instead.
        if isRoot {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    SignOutButton()
                } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.title3)
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Review").font(.headline)
                    Text("Decision Panel")
                        .font(.caption2)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                }
            }
        }
        if pinnedID != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Next profile") { Task { await advance() } }
                    .disabled(isAdvancing)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
        } else if let errorMessage {
            messageState("exclamationmark.triangle", "Something went wrong", errorMessage)
        } else if let pinned {
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.md) {
                    PersonCard(profile: pinned, photoURL: photoURLs[pinned.id], badge: "PINNED USER") {
                        inspected = pinned
                    }
                    actionButtons
                    if let phaseNote {
                        Text(phaseNote)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Palette.textSecondary)
                    }
                    Divider().padding(.vertical, DesignTokens.Spacing.xs)
                    candidateSection
                }
                .padding(DesignTokens.Spacing.md)
            }
        } else {
            messageState("checkmark.circle", "Queue is empty",
                         "No one is waiting to be matched right now.")
        }
    }

    private var actionButtons: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Button { confirmingMatch = true } label: {
                Label("Match", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
            }
            .tint(.green)
            .disabled(candidates.isEmpty || isMatching)
            Button { phaseNote = "Boost lands in Phase 10." } label: {
                Label("Boost", systemImage: "bolt.fill").frame(maxWidth: .infinity)
            }
            .tint(.blue)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var currentCandidate: Profile? {
        candidates.indices.contains(candidateIndex) ? candidates[candidateIndex] : nil
    }

    @ViewBuilder
    private var candidateSection: some View {
        if candidates.isEmpty {
            emptyCandidates
        } else {
            VStack(spacing: DesignTokens.Spacing.sm) {
                HStack {
                    Button {
                        withAnimation { candidateIndex = max(0, candidateIndex - 1) }
                    } label: { Image(systemName: "chevron.left") }
                    .disabled(candidateIndex == 0)
                    Spacer()
                    Text("Candidate \(candidateIndex + 1) of \(candidates.count)")
                        .font(DesignTokens.Typography.body)
                    Spacer()
                    Button {
                        withAnimation { candidateIndex = min(candidates.count - 1, candidateIndex + 1) }
                    } label: { Image(systemName: "chevron.right") }
                    .disabled(candidateIndex == candidates.count - 1)
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)

                TabView(selection: $candidateIndex) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        PersonCard(profile: candidate, photoURL: photoURLs[candidate.id], badge: nil) {
                            inspected = candidate
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 360)

                Text("Swipe left or right to see other matches")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var emptyCandidates: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text("No mutual matches yet.")
                .font(DesignTokens.Typography.titleMedium)
            if let stats {
                Text("Likes received \(stats.received) · given \(stats.given)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                Text(recommendation(for: stats))
                    .font(DesignTokens.Typography.body)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    private func recommendation(for stats: LikeStats) -> String {
        if stats.given == 0 {
            return "They haven't liked anyone yet — boosting won't help. Move on with Next profile."
        }
        if stats.received == 0 {
            return "They're active but aren't being seen — consider a Boost."
        }
        return "They have likes both ways but no mutual yet. Move on with Next profile."
    }

    private func messageState(_ icon: String, _ title: String, _ message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            Text(title).font(DesignTokens.Typography.titleMedium)
            Text(message)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        errorMessage = nil
        phaseNote = nil
        pinned = nil
        candidates = []
        candidateIndex = 0
        stats = nil
        photoURLs = [:]
        defer { isLoading = false }
        do {
            // First load of a jump-to-pin pins the chosen user; afterwards (and
            // always for the root tab) fall back to the front of the queue.
            let targetID: UUID?
            if let override = pendingOverride {
                targetID = override
                pendingOverride = nil
            } else {
                targetID = try await matchmaker.nextQueuedUser()
            }
            guard let id = targetID else {
                pinnedID = nil
                return
            }
            pinnedID = id
            let pinnedProfile = try await profiles.fetchProfile(userID: id)
            pinned = pinnedProfile
            candidates = try await matchmaker.candidates(for: id)
            if candidates.isEmpty {
                stats = try await matchmaker.likeStats(for: id)
            }
            await loadPhotos(for: [pinnedProfile].compactMap { $0 } + candidates)
        } catch is CancellationError {
            // Transient task cancellation (view re-identified during the
            // role-gate → tab transition) — a fresh load follows; don't show it.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPhotos(for people: [Profile]) async {
        // Resolve URLs incrementally (pinned is first, so it renders soonest)
        // and warm the decoded-image cache in the background so swiping the
        // candidate carousel is instant.
        for person in people {
            guard let photos = try? await profiles.listPhotos(userID: person.id),
                  let first = photos.first,
                  let url = try? await profiles.signedPhotoURL(for: first.storagePath) else { continue }
            photoURLs[person.id] = url
            Task { await ImageCache.shared.load(url) }
        }
    }

    private func createMatch() async {
        guard let pinnedID, let candidate = currentCandidate else { return }
        isMatching = true
        defer { isMatching = false }
        do {
            try await matches.createMatch(pinnedID, candidate.id)
            await load()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func advance() async {
        guard let id = pinnedID else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        do {
            try await matchmaker.requeue(userID: id)
            await load()
        } catch is CancellationError {
            // Transient task cancellation (view re-identified during the
            // role-gate → tab transition) — a fresh load follows; don't show it.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A photo card for a person with their key info overlaid, plus an optional
/// badge (e.g. "PINNED USER"). Tapping opens the full profile.
private struct PersonCard: View {
    let profile: Profile
    let photoURL: URL?
    let badge: String?
    let onTap: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            photo
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .center,
                endPoint: .bottom
            )
            info
        }
        .frame(height: 360)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.lg))
        .overlay(alignment: .topLeading) { badgeView }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var photo: some View {
        if let photoURL {
            CachedImage(url: photoURL) {
                placeholder.overlay(ProgressView())
            }
        } else {
            placeholder.overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.7))
            )
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [.indigo.opacity(0.5), .purple.opacity(0.5)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(profile.age.map { "\(profile.displayName), \($0)" } ?? profile.displayName)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            Label(profile.location, systemImage: "mappin.and.ellipse")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
            HStack(spacing: DesignTokens.Spacing.md) {
                if let height = profile.heightCm { chip("\(height) cm", "ruler") }
                if let income = profile.incomeAnnual { chip("\(income)", "banknote") }
                if let interest = profile.interests.first { chip(interest, "heart") }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.95))
        }
        .padding(DesignTokens.Spacing.lg)
    }

    private func chip(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private var badgeView: some View {
        if let badge {
            Text(badge)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .background(DesignTokens.Palette.primary, in: Capsule())
                .padding(DesignTokens.Spacing.md)
        }
    }
}
