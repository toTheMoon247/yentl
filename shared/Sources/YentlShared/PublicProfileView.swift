import SwiftUI

/// Presentational, read-only rendering of a public profile — the way it looks
/// to other users inside Yentl. Photos, name + age, location, bio, interests,
/// and prompts. Takes already-loaded data so it stays dumb and reusable.
public struct PublicProfileCard: View {
    private let profile: Profile
    private let photoURLs: [URL]
    private let prompts: [ProfilePrompt]

    public init(profile: Profile, photoURLs: [URL], prompts: [ProfilePrompt]) {
        self.profile = profile
        self.photoURLs = photoURLs
        self.prompts = prompts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            photos

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(nameAndAge)
                    .font(DesignTokens.Typography.titleMedium)
                Label(profile.location, systemImage: "mappin.and.ellipse")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)

            if let bio = profile.bio, !bio.isEmpty {
                section("About") {
                    Text(bio).font(DesignTokens.Typography.body)
                }
            }

            if !profile.interests.isEmpty {
                section("Interests") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            ForEach(profile.interests, id: \.self) { interest in
                                Text(interest)
                                    .font(DesignTokens.Typography.caption)
                                    .padding(.horizontal, DesignTokens.Spacing.md)
                                    .padding(.vertical, DesignTokens.Spacing.xs)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
            }

            ForEach(prompts) { prompt in
                section(prompt.prompt) {
                    Text(prompt.answer).font(DesignTokens.Typography.body)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    private var nameAndAge: String {
        if let age = profile.age { return "\(profile.displayName), \(age)" }
        return profile.displayName
    }

    @ViewBuilder
    private var photos: some View {
        if photoURLs.isEmpty {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md)
                .fill(.quaternary)
                .frame(height: 360)
                .overlay {
                    Image(systemName: "person.crop.rectangle")
                        .font(.system(size: 44))
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
        } else {
            TabView {
                ForEach(photoURLs, id: \.self) { url in
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                    .clipped()
                }
            }
            .frame(height: 360)
            #if os(iOS)
            .tabViewStyle(.page)
            #endif
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md))
            .padding(.horizontal, DesignTokens.Spacing.lg)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Spacing.lg)
    }
}

/// Loads a user's profile (basics, photos, prompts) and renders it. Used by
/// the consumer app (own profile / wizard preview, `showHiddenFields: false`)
/// and the matchmaker app (`showHiddenFields: true`, which adds the hidden
/// height/income block). Requires `ProfileService` in the environment.
public struct ProfileScreen: View {
    private let userID: UUID
    private let showHiddenFields: Bool

    @Environment(ProfileService.self) private var profiles
    @State private var profile: Profile?
    @State private var photoURLs: [URL] = []
    @State private var prompts: [ProfilePrompt] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    public init(userID: UUID, showHiddenFields: Bool) {
        self.userID = userID
        self.showHiddenFields = showHiddenFields
    }

    public var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let profile {
                ScrollView {
                    PublicProfileCard(profile: profile, photoURLs: photoURLs, prompts: prompts)
                    if showHiddenFields {
                        HiddenFieldsSection(profile: profile)
                    }
                }
            } else if let errorMessage {
                errorView(errorMessage)
            } else {
                Text("No profile yet.")
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
        }
        .task(id: userID) { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            guard let loaded = try await profiles.fetchProfile(userID: userID) else {
                profile = nil
                return
            }
            let photos = try await profiles.listPhotos(userID: userID)
            var urls: [URL] = []
            for photo in photos {
                if let url = try? await profiles.signedPhotoURL(for: photo.storagePath) {
                    urls.append(url)
                }
            }
            prompts = try await profiles.listPrompts(userID: userID)
            photoURLs = urls
            profile = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DesignTokens.Spacing.xl)
    }
}

/// Hidden matchmaker fields — height and income — shown only inside Yentl
/// Matchmaker. Never rendered in the consumer app.
private struct HiddenFieldsSection: View {
    let profile: Profile

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Label("Matchmaker only", systemImage: "eye.slash")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            row("Height", profile.heightCm.map { "\($0) cm" })
            row("Income", profile.incomeAnnual.map { "\($0)" })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.lg)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md))
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.top, DesignTokens.Spacing.md)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(DesignTokens.Palette.textSecondary)
            Spacer()
            Text(value ?? "—")
        }
        .font(DesignTokens.Typography.body)
    }
}
