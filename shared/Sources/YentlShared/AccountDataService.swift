//
//  AccountDataService.swift
//  YentlShared
//
//  Phase 11 Slice 2: account data rights (GDPR / App Store 5.1.1).
//  - exportMyData(): the `export_my_data` RPC, pretty-printed for download.
//  - deleteAccount(): the `delete-account` Edge Function (Storage + app data +
//    auth login). On success the session is dead — the caller must sign out.
//

import Foundation
import Supabase

public enum AccountDataError: LocalizedError {
    case notSignedIn
    case unexpected(any Error)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .unexpected(let error):
            return error.localizedDescription
        }
    }
}

@MainActor
public final class AccountDataService {
    public static let shared = AccountDataService()

    private init() {}

    /// The signed-in user's data as pretty-printed JSON `Data` — the raw
    /// `export_my_data` document, ready to write to a file for a share sheet.
    public func exportMyData() async throws -> Data {
        do {
            let raw = try await Backend.supabase.rpc("export_my_data").execute().data
            // Pretty-print (stable key order) so the download reads cleanly;
            // fall back to the raw bytes if it somehow isn't valid JSON.
            if let object = try? JSONSerialization.jsonObject(with: raw),
               let pretty = try? JSONSerialization.data(
                   withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                return pretty
            }
            return raw
        } catch {
            if error is CancellationError { throw error }
            throw AccountDataError.unexpected(error)
        }
    }

    /// Permanently deletes the caller's account: Storage photos, every app
    /// table (cascade), and the auth login. Irreversible. After this returns,
    /// the caller MUST sign out — the session no longer maps to a user.
    public func deleteAccount() async throws {
        do {
            try await Backend.supabase.functions.invoke(
                "delete-account",
                options: FunctionInvokeOptions(method: .post)
            )
        } catch {
            if error is CancellationError { throw error }
            throw AccountDataError.unexpected(error)
        }
    }
}
