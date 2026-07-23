//
//  AccountPrivacyView.swift
//  Yentl
//
//  Phase 11 Slice 2: the consumer data-rights screen (App Store 5.1.1 / GDPR).
//  "Download my data" exports the export_my_data document to a share sheet;
//  "Delete account" permanently erases the account (with a confirmation) and
//  signs out.
//

import SwiftUI
import UIKit
import YentlShared

struct AccountPrivacyView: View {
    @Environment(AuthService.self) private var auth

    @State private var isExporting = false
    @State private var exportFile: ExportFile?
    @State private var isDeleting = false
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await exportData() }
                } label: {
                    HStack {
                        Label("Download my data", systemImage: "square.and.arrow.up")
                        if isExporting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isExporting || isDeleting)
            } header: {
                Text("Your data")
            } footer: {
                Text("A copy of your profile, matches, payments, and activity as a "
                   + "JSON file you can save or share.")
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    HStack {
                        Label("Delete account", systemImage: "trash")
                        if isDeleting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isExporting || isDeleting)
            } header: {
                Text("Danger zone")
            } footer: {
                Text("Permanently erases your profile, photos, matches, and messages. "
                   + "This can't be undone.")
            }
        }
        .navigationTitle("Account & Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportFile) { file in
            ShareSheet(activityItems: [file.url])
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently erases your profile, photos, matches, and messages. "
               + "It can't be undone.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { errorMessage != nil },
                                 set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }

    private func exportData() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await AccountDataService.shared.exportMyData()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("yentl-my-data.json")
            try data.write(to: url, options: .atomic)
            exportFile = ExportFile(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await AccountDataService.shared.deleteAccount()
            // The session no longer maps to a user — sign out to return to the
            // signed-out screen. Best-effort: even if this throws, the account
            // is already gone.
            try? await auth.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Wraps a temp-file URL so `.sheet(item:)` can present the share sheet.
private struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Minimal UIActivityViewController bridge for the data download.
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
