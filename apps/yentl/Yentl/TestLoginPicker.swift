//
//  TestLoginPicker.swift
//  Yentl
//
//  DEBUG-only: sign in as a seeded test user (real email/password auth) so a
//  developer can test both sides of the app — male/female, match sender/
//  receiver — without juggling multiple Google accounts. Never compiled into
//  release builds.
//
//  Requires the seeds to have a password — run supabase/dev/set_seed_passwords.sql
//  once. Switching "logs out + logs in" under the hood, so it's one tap.
//

#if DEBUG
import SwiftUI
import YentlShared

struct TestLoginPicker: View {
    let onSwitched: () -> Void

    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var working: String?
    @State private var errorMessage: String?

    private static let password = "yentltest"

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.caption) }
                }
                Section("Women") {
                    ForEach(Self.accounts(prefix: "f", names: Self.femaleNames)) { account in
                        row(account)
                    }
                }
                Section("Men") {
                    ForEach(Self.accounts(prefix: "m", names: Self.maleNames)) { account in
                        row(account)
                    }
                }
            }
            .navigationTitle("Log in as… (DEBUG)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
            }
        }
    }

    private func row(_ account: TestAccount) -> some View {
        Button {
            Task { await switchTo(account.email) }
        } label: {
            HStack {
                Text(account.label)
                Spacer()
                if working == account.email { ProgressView() }
            }
        }
        .disabled(working != nil)
    }

    private func switchTo(_ email: String) async {
        working = email
        errorMessage = nil
        defer { working = nil }
        do {
            // signInWithEmail replaces the current session — don't sign out
            // first, or a failed sign-in would leave us logged out.
            try await auth.signInWithEmail(email, password: Self.password)
            onSwitched()
        } catch {
            errorMessage = "Couldn't sign in as \(email): \(error.localizedDescription)"
        }
    }

    private struct TestAccount: Identifiable {
        let email: String
        let label: String
        var id: String { email }
    }

    // Mirrors the names in supabase/dev/name_seed_profiles.sql so the picker
    // shows the same display names (e.g. "Kanyin" = seed-f-07).
    private static let femaleNames = [
        "Olivia", "Maya", "Sofia", "Aisha", "Hannah", "Noa", "Kanyin", "Emma",
        "Leila", "Yara", "Chloe", "Mia", "Tamar", "Zoe", "Amara", "Isabella",
        "Priya", "Nina", "Grace", "Ava"
    ]
    private static let maleNames = [
        "Liam", "Noah", "Ethan", "Omar", "Daniel", "Lucas", "Adam", "Mateo",
        "Eitan", "Yusuf", "Caleb", "Leo", "David", "Aaron", "Kofi", "James",
        "Arjun", "Ben", "Marco", "Theo"
    ]

    private static func accounts(prefix: String, names: [String]) -> [TestAccount] {
        names.enumerated().map { index, name in
            let nn = String(format: "%02d", index + 1)
            return TestAccount(email: "seed-\(prefix)-\(nn)@yentl.test", label: name)
        }
    }
}
#endif
