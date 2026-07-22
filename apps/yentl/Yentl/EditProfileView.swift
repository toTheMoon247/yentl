//
//  EditProfileView.swift
//  Yentl
//
//  Post-completion profile editing. A single scrollable form (unlike the
//  stepped creation wizard), prefilled from the current profile. Photos are
//  managed inline via PhotoManager and persist immediately; the other fields
//  are saved together when the user taps Save.
//

import SwiftUI
import YentlShared

struct EditProfileView: View {
    /// Called when editing finishes (saved) or is cancelled.
    let onDone: () -> Void
    /// Called only on a successful save, just before `onDone` — lets the
    /// rejected-profile screen resubmit after edits while a plain cancel
    /// changes nothing. Optional so existing call sites are unaffected.
    var onSaved: (() -> Void)?

    @Environment(ProfileService.self) private var profiles

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var displayName = ""
    @State private var dateOfBirth = Date()
    @State private var gender: Gender = .male
    @State private var location = ""
    @State private var bio = ""
    @State private var selectedInterests: Set<String> = []
    @State private var promptChoices: [String?] = Array(repeating: nil, count: ProfilePresets.maxPrompts)
    @State private var promptAnswers: [String] = Array(repeating: "", count: ProfilePresets.maxPrompts)
    @State private var heightCm = 170
    @State private var incomeText = ""
    @State private var photoCount = 0

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    form
                }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onDone).disabled(isSaving)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton().disabled(photoCount == 0 || isSaving)
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
        }
        .task { await load() }
    }

    private var form: some View {
        Form {
            Section("About you") {
                TextField("Display name", text: $displayName)
                DatePicker("Date of birth", selection: $dateOfBirth, displayedComponents: .date)
                Picker("Gender", selection: $gender) {
                    ForEach(Gender.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Location (city)", text: $location)
            }

            PhotoManager(photoCount: $photoCount)

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

            Section {
                Picker("Height", selection: $heightCm) {
                    ForEach(140...210, id: \.self) { Text("\($0) cm").tag($0) }
                }
                TextField("Annual income", text: $incomeText)
                    .keyboardType(.numberPad)
            } header: {
                Text("Private details")
            } footer: {
                Text("Only matchmakers can see your height and income.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func toggle(_ interest: String) {
        if selectedInterests.contains(interest) {
            selectedInterests.remove(interest)
        } else {
            selectedInterests.insert(interest)
        }
    }

    private var income: Int? { Int(incomeText.trimmingCharacters(in: .whitespaces)) }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !location.trimmingCharacters(in: .whitespaces).isEmpty
            && (income ?? -1) >= 0
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let profile = try await profiles.fetchMyProfile() else { return }
            displayName = profile.displayName
            dateOfBirth = Self.dateFormatter.date(from: profile.dateOfBirth) ?? Date()
            gender = profile.gender
            location = profile.location
            bio = profile.bio ?? ""
            selectedInterests = Set(profile.interests)
            heightCm = profile.heightCm ?? 170
            incomeText = profile.incomeAnnual.map(String.init) ?? ""

            let prompts = try await profiles.listPrompts(userID: profile.id)
            for (index, prompt) in prompts.prefix(ProfilePresets.maxPrompts).enumerated() {
                promptChoices[index] = prompt.prompt
                promptAnswers[index] = prompt.answer
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard let income else { return }
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
            try await profiles.saveBasics(
                displayName: displayName.trimmingCharacters(in: .whitespaces),
                dateOfBirth: Self.dateFormatter.string(from: dateOfBirth),
                gender: gender,
                location: location.trimmingCharacters(in: .whitespaces)
            )
            let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            try await profiles.saveDetails(
                bio: trimmedBio.isEmpty ? nil : trimmedBio,
                interests: Array(selectedInterests).sorted(),
                prompts: prompts
            )
            try await profiles.savePrivateDetails(heightCm: heightCm, incomeAnnual: income)
            onSaved?()
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

#Preview {
    EditProfileView(onDone: {})
        .environment(ProfileService.shared)
}
