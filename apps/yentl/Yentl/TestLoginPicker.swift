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
                if let realEmail = savedRealEmail {
                    Section("My account") {
                        Button {
                            Task { await switchBackToReal() }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.uturn.backward")
                                Text(realEmail)
                                Spacer()
                                if working == realEmail { ProgressView() }
                            }
                        }
                        .disabled(working != nil)
                    }
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
            // Before impersonating a seed, snapshot the real (non-seed) account
            // so the "My account" row can restore it without redoing OAuth.
            if let current = auth.currentUserEmail,
               !current.contains("@yentl.test"),
               let tokens = await auth.currentSessionTokens() {
                let defaults = UserDefaults.standard
                defaults.set(tokens.accessToken, forKey: Self.kAccessToken)
                defaults.set(tokens.refreshToken, forKey: Self.kRefreshToken)
                defaults.set(current, forKey: Self.kRealEmail)
            }
            // signInWithEmail replaces the current session — don't sign out
            // first, or a failed sign-in would leave us logged out.
            try await auth.signInWithEmail(email, password: Self.password)
            onSwitched()
        } catch {
            errorMessage = "Couldn't sign in as \(email): \(error.localizedDescription)"
        }
    }

    /// Restore the real (Google) account from the snapshotted tokens.
    private func switchBackToReal() async {
        let defaults = UserDefaults.standard
        guard let accessToken = defaults.string(forKey: Self.kAccessToken),
              let refreshToken = defaults.string(forKey: Self.kRefreshToken),
              let email = defaults.string(forKey: Self.kRealEmail) else { return }
        working = email
        errorMessage = nil
        defer { working = nil }
        do {
            try await auth.restoreSession(accessToken: accessToken, refreshToken: refreshToken)
            onSwitched()
        } catch {
            errorMessage = "Couldn't switch back to \(email): \(error.localizedDescription)"
        }
    }

    private var savedRealEmail: String? {
        UserDefaults.standard.string(forKey: Self.kRealEmail)
    }

    private static let kAccessToken = "debug.realAccount.accessToken"
    private static let kRefreshToken = "debug.realAccount.refreshToken"
    private static let kRealEmail = "debug.realAccount.email"

    private struct TestAccount: Identifiable {
        let email: String
        let label: String
        var id: String { email }
    }

    // Mirrors the names in supabase/dev/name_seed_profiles.sql, which assigns by
    // email number — so index N here == seed-?-0N's display name (e.g. "Kanyin"
    // is #5 == seed-f-05, the profile that holds Kanyin.jpg).
    private static let femaleNames = [
        "Olivia", "Maya", "Sofia", "Aisha", "Kanyin", "Noa", "Hannah", "Emma",
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
