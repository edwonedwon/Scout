import Foundation
import Supabase
import AuthenticationServices
import CryptoKit

/// Lazily-built shared Supabase client. nil until `SupabaseConfig` is filled in, so the rest of the
/// app can compile and run local-only before the accounts exist.
enum SupabaseService {
    static let client: SupabaseClient? = {
        guard SupabaseConfig.isConfigured, let url = SupabaseConfig.supabaseURL else { return nil }
        return SupabaseClient(supabaseURL: url, supabaseKey: SupabaseConfig.anonKey)
    }()
}

/// Owns the authenticated session and drives the login UI. Backed by Supabase Auth (GoTrue):
/// email/password and Sign in with Apple (OIDC id-token flow). Secure-by-default — the SDK stores
/// the session in the Keychain and refreshes tokens automatically.
///
/// When Supabase isn't configured yet, `authDisabled` is true and the app proceeds without a gate
/// (local-only mode), so nothing breaks before P4 account setup.
@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published private(set) var session: Session?
    @Published var errorMessage: String?
    @Published var isBusy = false
    /// Set after sending a password-reset or sign-up confirmation email, to show a confirmation.
    @Published var infoMessage: String?
    /// When set, sign-up succeeded but the account needs email confirmation. The login form is
    /// replaced by a "check your email" waiting screen until the user confirms and signs in.
    @Published var pendingConfirmationEmail: String?

    let authDisabled: Bool
    var isAuthenticated: Bool { authDisabled || session != nil }
    var userEmail: String? { session?.user.email }

    private let client: SupabaseClient?
    private var observeTask: Task<Void, Never>?
    /// The raw nonce for an in-flight Sign in with Apple request (compared against the id token).
    private var appleNonce: String?

    private init() {
        client = SupabaseService.client
        authDisabled = (client == nil)
        guard let client else { return }
        // Reflect the persisted session immediately, then track every change.
        session = client.auth.currentSession
        observeTask = Task { [weak self] in
            for await (_, newSession) in client.auth.authStateChanges {
                await MainActor.run { self?.session = newSession }
            }
        }
    }

    // MARK: - Email / password

    func signIn(email: String, password: String) async {
        await run {
            _ = try await self.client!.auth.signIn(email: email.trimmed, password: password)
        }
    }

    func signUp(email: String, password: String) async {
        await run {
            let response = try await self.client!.auth.signUp(email: email.trimmed, password: password)
            // When email confirmation is on, `session` is nil until the user taps the link — switch
            // the UI to the waiting screen. Otherwise the authStateChanges stream signs them in.
            if response.session == nil {
                self.pendingConfirmationEmail = email.trimmed
            }
        }
    }

    /// Re-send the confirmation email for the pending sign-up.
    func resendConfirmation() async {
        guard let email = pendingConfirmationEmail else { return }
        await run {
            try await self.client!.auth.resend(email: email, type: .signup)
            self.infoMessage = "Confirmation email re-sent to \(email)."
        }
    }

    /// Leave the waiting screen (e.g. "use a different email" / back to sign in).
    func cancelPendingConfirmation() {
        pendingConfirmationEmail = nil
        errorMessage = nil
        infoMessage = nil
    }

    func resetPassword(email: String) async {
        await run {
            try await self.client!.auth.resetPasswordForEmail(email.trimmed)
            self.infoMessage = "Password reset email sent to \(email.trimmed)."
        }
    }

    func signOut() async {
        await run {
            try await self.client!.auth.signOut()
        }
        // Drop all synced rows so the next user never sees this user's data.
        try? await ScoutStore.shared.db.disconnectAndClear(clearLocal: false, soft: true)
    }

    // MARK: - Sign in with Apple

    /// Configure an `ASAuthorizationAppleIDRequest` (used by SwiftUI's `SignInWithAppleButton`).
    /// Generates a fresh nonce and sends only its SHA-256 hash to Apple; the raw nonce is kept to
    /// hand to Supabase, which verifies it against the `nonce` claim in the returned id token.
    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        appleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            // User-cancelled isn't an error worth surfacing.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = error.localizedDescription
        case .success(let auth):
            guard
                let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let nonce = appleNonce
            else {
                errorMessage = "Could not read the Apple credential."
                return
            }
            await run {
                _ = try await self.client!.auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
                )
            }
        }
    }

    // MARK: - Helpers

    /// Runs an auth call with shared busy/error handling on the main actor.
    private func run(_ body: @escaping () async throws -> Void) async {
        errorMessage = nil
        infoMessage = nil
        isBusy = true
        defer { isBusy = false }
        do { try await body() }
        catch { errorMessage = (error as? AuthError)?.localizedDescription ?? error.localizedDescription }
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Cryptographically-random nonce (Apple requires this to prevent replay attacks).
    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if status != errSecSuccess { random = UInt8.random(in: 0...255) }
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
