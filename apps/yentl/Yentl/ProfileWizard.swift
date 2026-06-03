//
//  ProfileWizard.swift
//  Yentl
//
//  Profile creation wizard. Steps:
//    1. Basics  — name, date of birth, gender, location.
//    2. Photos  — add (from the photo library), reorder, delete.
//    3. Details — bio, interests, prompts (optional).
//    4. Private — height + income (required; hidden matchmaker fields).
//    5. Preview — what others will see; "Finish" marks the profile complete.
//
//  Each step saves its data on "Next" without completing the profile; the
//  profile is marked complete at the end of the final step, which routes the
//  user to the home screen.
//

import PhotosUI
import SwiftUI
import UIKit
import YentlShared

struct ProfileWizard: View {
    /// Called after the profile has been saved and marked complete.
    let onComplete: () -> Void

    @State private var step: Step = .basics

    private enum Step {
        case basics, photos, details, privateDetails, preview
    }

    var body: some View {
        switch step {
        case .basics:
            BasicsStep(onSaved: { step = .photos })
        case .photos:
            PhotosStep(onBack: { step = .basics }, onNext: { step = .details })
        case .details:
            DetailsStep(onBack: { step = .photos }, onNext: { step = .privateDetails })
        case .privateDetails:
            PrivateDetailsStep(onBack: { step = .details }, onNext: { step = .preview })
        case .preview:
            PreviewStep(onBack: { step = .privateDetails }, onFinish: onComplete)
        }
    }
}

// MARK: - Step 1: Basics

private struct BasicsStep: View {
    let onSaved: () -> Void

    @Environment(ProfileService.self) private var profiles

    @State private var displayName = ""
    @State private var dateOfBirth = Self.defaultDateOfBirth
    @State private var gender: Gender = .male
    @State private var location = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("About you") {
                    TextField("Display name", text: $displayName)
                        .textContentType(.name)
                    DatePicker(
                        "Date of birth",
                        selection: $dateOfBirth,
                        in: Self.dateRange,
                        displayedComponents: .date
                    )
                    Picker("Gender", selection: $gender) {
                        ForEach(Gender.allCases, id: \.self) { gender in
                            Text(gender.displayName).tag(gender)
                        }
                    }
                    TextField("Location (city)", text: $location)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        centeredLabel(isSaving ? nil : "Next")
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .navigationTitle("Create your profile")
            .disabled(isSaving)
        }
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !location.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await profiles.saveBasics(
                displayName: displayName.trimmingCharacters(in: .whitespaces),
                dateOfBirth: Self.dateFormatter.string(from: dateOfBirth),
                gender: gender,
                location: location.trimmingCharacters(in: .whitespaces)
            )
            onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Date helpers — yyyy-MM-dd to match the Postgres `date` column.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static var defaultDateOfBirth: Date {
        Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date()
    }

    private static var dateRange: ClosedRange<Date> {
        let now = Date()
        let oldest = Calendar.current.date(byAdding: .year, value: -100, to: now) ?? now
        let youngest = Calendar.current.date(byAdding: .year, value: -18, to: now) ?? now
        return oldest...youngest
    }
}

// MARK: - Step 2: Photos

private struct PhotosStep: View {
    let onBack: () -> Void
    let onNext: () -> Void

    @Environment(ProfileService.self) private var profiles

    @State private var photos: [ProfilePhoto] = []
    @State private var urls: [UUID: URL] = [:]
    @State private var picked: [PhotosPickerItem] = []
    @State private var isLoading = false
    @State private var isUploading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(
                        selection: $picked,
                        maxSelectionCount: 6,
                        matching: .images
                    ) {
                        Label("Add photos", systemImage: "photo.badge.plus")
                    }
                    .disabled(isUploading)
                    if isUploading {
                        HStack { ProgressView(); Text("Uploading…") }
                    }
                } footer: {
                    Text("Add at least one photo. Drag to reorder, swipe to delete.")
                }

                Section("Your photos") {
                    if photos.isEmpty && !isLoading {
                        Text("No photos yet.")
                            .foregroundStyle(DesignTokens.Palette.textSecondary)
                    }
                    ForEach(photos) { photo in
                        PhotoRow(url: urls[photo.id])
                    }
                    .onDelete(perform: delete)
                    .onMove(perform: move)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        onNext()
                    } label: {
                        centeredLabel("Next")
                    }
                    .disabled(photos.isEmpty || isUploading)
                }
            }
            .navigationTitle("Add your photos")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", action: onBack).disabled(isUploading)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton().disabled(photos.isEmpty)
                }
            }
        }
        .task { await load() }
        .onChange(of: picked) { _, items in
            Task { await upload(items) }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            photos = try await profiles.listPhotos()
            for photo in photos where urls[photo.id] == nil {
                urls[photo.id] = try? await profiles.signedPhotoURL(for: photo.storagePath)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upload(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        errorMessage = nil
        isUploading = true
        defer { isUploading = false; picked = [] }
        do {
            for item in items {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let jpeg = ImageDownscaler.jpeg(from: data) else { continue }
                try await profiles.uploadPhoto(jpegData: jpeg)
            }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        let targets = offsets.map { photos[$0] }
        Task {
            errorMessage = nil
            do {
                for photo in targets {
                    try await profiles.deletePhoto(photo)
                    urls[photo.id] = nil
                }
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        photos.move(fromOffsets: offsets, toOffset: destination)
        let reordered = photos
        Task {
            do { try await profiles.reorderPhotos(reordered) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Step 3: Details (bio, interests, prompts)

private struct DetailsStep: View {
    let onBack: () -> Void
    let onNext: () -> Void

    @Environment(ProfileService.self) private var profiles

    @State private var bio = ""
    @State private var selectedInterests: Set<String> = []
    @State private var promptChoices: [String?] = Array(repeating: nil, count: ProfilePresets.maxPrompts)
    @State private var promptAnswers: [String] = Array(repeating: "", count: ProfilePresets.maxPrompts)
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Bio") {
                    TextField("Tell people about yourself…", text: $bio, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Interests") {
                    ForEach(ProfilePresets.interests, id: \.self) { interest in
                        Button {
                            toggle(interest)
                        } label: {
                            HStack {
                                Text(interest).foregroundStyle(DesignTokens.Palette.textPrimary)
                                Spacer()
                                if selectedInterests.contains(interest) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(DesignTokens.Palette.primary)
                                }
                            }
                        }
                    }
                }

                ForEach(0..<ProfilePresets.maxPrompts, id: \.self) { index in
                    Section("Prompt \(index + 1)") {
                        Picker("Question", selection: $promptChoices[index]) {
                            Text("None").tag(String?.none)
                            ForEach(ProfilePresets.prompts, id: \.self) { question in
                                Text(question).tag(String?.some(question))
                            }
                        }
                        if promptChoices[index] != nil {
                            TextField("Your answer", text: $promptAnswers[index], axis: .vertical)
                                .lineLimit(2...4)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        centeredLabel(isSaving ? nil : "Next")
                    }
                    .disabled(isSaving)
                }
            }
            .navigationTitle("About you")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", action: onBack).disabled(isSaving)
                }
            }
            .disabled(isSaving)
        }
    }

    private func toggle(_ interest: String) {
        if selectedInterests.contains(interest) {
            selectedInterests.remove(interest)
        } else {
            selectedInterests.insert(interest)
        }
    }

    private func save() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        var prompts: [ProfilePromptDraft] = []
        for index in 0..<ProfilePresets.maxPrompts {
            guard let question = promptChoices[index] else { continue }
            let answer = promptAnswers[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { continue }
            prompts.append(ProfilePromptDraft(prompt: question, answer: answer))
        }

        do {
            let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            try await profiles.saveDetails(
                bio: trimmedBio.isEmpty ? nil : trimmedBio,
                interests: Array(selectedInterests).sorted(),
                prompts: prompts
            )
            onNext()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Step 4: Private details (height, income) — required

private struct PrivateDetailsStep: View {
    let onBack: () -> Void
    let onNext: () -> Void

    @Environment(ProfileService.self) private var profiles

    @State private var heightCm = 170
    @State private var incomeText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Height", selection: $heightCm) {
                        ForEach(140...210, id: \.self) { cm in
                            Text("\(cm) cm").tag(cm)
                        }
                    }
                    TextField("Annual income", text: $incomeText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Private details")
                } footer: {
                    Text(
                        "Only Yentl's matchmakers can see your height and income — "
                        + "they're never shown to other users. Both are required."
                    )
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        centeredLabel(isSaving ? nil : "Next")
                    }
                    .disabled(!canContinue || isSaving)
                }
            }
            .navigationTitle("Almost done")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", action: onBack).disabled(isSaving)
                }
            }
            .disabled(isSaving)
        }
    }

    private var income: Int? {
        Int(incomeText.trimmingCharacters(in: .whitespaces))
    }

    private var canContinue: Bool {
        if let income { return income >= 0 }
        return false
    }

    private func save() async {
        guard let income else { return }
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await profiles.savePrivateDetails(heightCm: heightCm, incomeAnnual: income)
            onNext()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Step 5: Preview ("what others will see") + finish

private struct PreviewStep: View {
    let onBack: () -> Void
    let onFinish: () -> Void

    @Environment(AuthService.self) private var auth
    @Environment(ProfileService.self) private var profiles
    @State private var isFinishing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let userID {
                    ProfileScreen(userID: userID, showHiddenFields: false)
                        .frame(maxHeight: .infinity)
                } else {
                    Text("Couldn't load preview.")
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .frame(maxHeight: .infinity)
                }

                VStack(spacing: DesignTokens.Spacing.sm) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.red)
                    }
                    Button {
                        Task { await finish() }
                    } label: {
                        centeredLabel(isFinishing ? nil : "Finish")
                            .padding(.vertical, DesignTokens.Spacing.xs)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isFinishing)
                }
                .padding(DesignTokens.Spacing.lg)
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", action: onBack).disabled(isFinishing)
                }
            }
        }
    }

    private var userID: UUID? {
        auth.currentUserIDString.flatMap(UUID.init)
    }

    private func finish() async {
        errorMessage = nil
        isFinishing = true
        defer { isFinishing = false }
        do {
            try await profiles.markProfileComplete()
            onFinish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PhotoRow: View {
    let url: URL?

    var body: some View {
        HStack {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.sm))
            } else {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.sm)
                    .fill(.quaternary)
                    .frame(width: 56, height: 56)
                    .overlay(ProgressView())
            }
            Text("Photo")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
        }
    }
}

// MARK: - Helpers

/// Centered button label; pass nil to show a spinner instead of text.
@ViewBuilder
private func centeredLabel(_ title: String?) -> some View {
    HStack {
        Spacer()
        if let title { Text(title) } else { ProgressView() }
        Spacer()
    }
}

/// Downscales arbitrary image data to a reasonably-sized JPEG for upload.
/// Lives in the app target (UIKit isn't available in the shared package,
/// which also builds for macOS).
private enum ImageDownscaler {
    static func jpeg(from data: Data, maxDimension: CGFloat = 1200, quality: CGFloat = 0.8) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / longest)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

#Preview {
    ProfileWizard(onComplete: {})
        .environment(ProfileService.shared)
}
