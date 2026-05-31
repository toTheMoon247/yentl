import SwiftUI

/// Sign-out button shared by both apps.
///
/// Reads `AuthService` from the environment and drives `signOut()`. Disables
/// itself while the request is in flight to prevent double taps. Note that
/// `AuthService.signOut()` clears the local session and flips auth state to
/// `.signedOut` before the network revoke call, so the hosting view is routed
/// away as soon as sign-out begins — a thrown network error (e.g. offline) is
/// therefore harmless and intentionally ignored here.
public struct SignOutButton: View {
    private let title: String

    @Environment(AuthService.self) private var auth
    @State private var isWorking = false

    public init(_ title: String = "Sign out") {
        self.title = title
    }

    public var body: some View {
        Button(title) {
            isWorking = true
            Task {
                try? await auth.signOut()
                isWorking = false
            }
        }
        .buttonStyle(.bordered)
        .disabled(isWorking)
    }
}
