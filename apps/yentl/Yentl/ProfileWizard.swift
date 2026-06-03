//
//  ProfileWizard.swift
//  Yentl
//
//  Profile creation wizard. Slice 1 is the "basics" step only (name, date of
//  birth, gender, location); later slices add photos, bio, prompts, interests,
//  and the hidden matchmaker fields (height, income), then a preview.
//
//  On finish it saves the profile via ProfileService and calls `onComplete`,
//  which re-evaluates routing and sends the user to the home screen.
//

import SwiftUI
import YentlShared

struct ProfileWizard: View {
    /// Called after the profile has been saved.
    let onComplete: () -> Void

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
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("Save & continue")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .navigationTitle("Create your profile")
            .disabled(isSaving)
        }
    }

    // MARK: - Validation / actions

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
            onComplete()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Date helpers

    /// Fixed `yyyy-MM-dd` formatter to match the Postgres `date` column.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Default the picker to a plausible adult age (~25) rather than today.
    private static var defaultDateOfBirth: Date {
        Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date()
    }

    /// Allow ages roughly 18–100; the 18+ rule itself is confirmed in onboarding.
    private static var dateRange: ClosedRange<Date> {
        let now = Date()
        let oldest = Calendar.current.date(byAdding: .year, value: -100, to: now) ?? now
        let youngest = Calendar.current.date(byAdding: .year, value: -18, to: now) ?? now
        return oldest...youngest
    }
}

#Preview {
    ProfileWizard(onComplete: {})
        .environment(ProfileService.shared)
}
