//
//  AppleSignIn.swift
//  YentlShared
//
//  Native "Sign in with Apple" plumbing. Runs the system authorization sheet
//  and hands back exactly what Supabase's `signInWithIdToken` needs: Apple's
//  identity token (a JWT) plus the *raw* nonce that was hashed into the request.
//
//  Nonce round-trip: we generate a random raw nonce, send SHA256(rawNonce) to
//  Apple (which signs it into the token's `nonce` claim), and give the raw
//  value to Supabase — Supabase re-hashes it and checks it matches, which is
//  what defeats token-replay. So the raw nonce, not the hash, must come back.
//
//  iOS-only: the authorization UI needs UIKit for its presentation anchor. The
//  shared package also builds for macOS (so `swift build`/tests run on the CI
//  host), hence the guard; both apps ship on iOS, so nothing is lost.
//

#if os(iOS)
import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Errors from the native Apple authorization step (before Supabase is involved).
enum AppleSignInError: LocalizedError {
    /// Apple returned an authorization but without a usable identity token.
    case missingIdentityToken

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken:
            return "Apple didn't return an identity token. Please try again."
        }
    }
}

/// Drives one `ASAuthorizationController` round-trip. Create, `await start()`,
/// discard. Holds a strong reference to the controller for the duration (the
/// controller retains its delegate only weakly, so letting it deallocate would
/// silently drop the callbacks).
@MainActor
final class AppleSignInCoordinator: NSObject {
    private var continuation: CheckedContinuation<(idToken: String, rawNonce: String), Error>?
    private var controller: ASAuthorizationController?
    private let rawNonce: String

    override init() {
        self.rawNonce = Self.randomNonceString()
        super.init()
    }

    /// Presents the system Sign in with Apple sheet and resumes with the
    /// identity token + raw nonce, or throws. User cancellation surfaces as the
    /// underlying `ASAuthorizationError` (caller maps it as it sees fit).
    func start() async throws -> (idToken: String, rawNonce: String) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = Self.sha256(rawNonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<(idToken: String, rawNonce: String), Error>) {
        continuation?.resume(with: result)
        continuation = nil
        controller = nil
    }

    // MARK: - Nonce helpers

    /// A cryptographically random alphanumeric nonce (Apple's documented
    /// recipe, minus the crash-on-failure: `SecRandomCopyBytes` effectively
    /// never fails, but we fall back to the platform CSPRNG rather than trap).
    static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] =
            Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var byte: UInt8 = 0
            if SecRandomCopyBytes(kSecRandomDefault, 1, &byte) != errSecSuccess {
                byte = UInt8.random(in: 0...255)  // CSPRNG-backed on Apple platforms
            }
            // Reject bytes >= charset.count to avoid modulo bias.
            if byte < UInt8(charset.count) {
                result.append(charset[Int(byte)])
                remaining -= 1
            }
        }
        return result
    }

    /// Lowercase hex SHA-256 of `input` — the form Apple expects in `nonce`.
    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            finish(.failure(AppleSignInError.missingIdentityToken))
            return
        }
        finish(.success((idToken: idToken, rawNonce: rawNonce)))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(.failure(error))
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}
#endif
