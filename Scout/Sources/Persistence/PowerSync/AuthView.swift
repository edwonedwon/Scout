import SwiftUI
import AuthenticationServices

/// The sign-in / sign-up gate shown when no user is authenticated. Shared across iOS and macOS.
/// Offers Sign in with Apple and email + password, plus a password-reset path.
struct AuthView: View {
    @EnvironmentObject private var auth: AuthManager

    enum Mode { case signIn, signUp, reset }
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""

    private var title: String {
        switch mode {
        case .signIn: return "Welcome back"
        case .signUp: return "Create your account"
        case .reset:  return "Reset password"
        }
    }
    private var primaryLabel: String {
        switch mode {
        case .signIn: return "Sign In"
        case .signUp: return "Sign Up"
        case .reset:  return "Send Reset Link"
        }
    }
    private var canSubmit: Bool {
        guard email.contains("@") else { return false }
        return mode == .reset || password.count >= 6
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color(hexString: "#FF6B35"))
                Text("Script Scout").font(.largeTitle.bold())
                Text(title).font(.headline).foregroundStyle(.secondary)
            }
            .padding(.top, 12)

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                if mode != .reset {
                    SecureField("Password", text: $password)
                        .textContentType(mode == .signUp ? .newPassword : .password)
                        .textFieldStyle(.roundedBorder)
                }

                if let error = auth.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let info = auth.infoMessage {
                    Text(info).font(.callout).foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: submit) {
                    HStack {
                        if auth.isBusy { ProgressView().controlSize(.small) }
                        Text(primaryLabel).bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hexString: "#FF6B35"))
                .disabled(!canSubmit || auth.isBusy)
            }

            if mode != .reset {
                HStack {
                    VStack { Divider() }
                    Text("or").font(.caption).foregroundStyle(.secondary)
                    VStack { Divider() }
                }

                SignInWithAppleButton(.continue) { request in
                    auth.configureAppleRequest(request)
                } onCompletion: { result in
                    Task { await auth.handleAppleCompletion(result) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            footerLinks
        }
        .padding(32)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var footerLinks: some View {
        VStack(spacing: 6) {
            switch mode {
            case .signIn:
                Button("Forgot password?") { switchTo(.reset) }
                HStack(spacing: 4) {
                    Text("New here?").foregroundStyle(.secondary)
                    Button("Create an account") { switchTo(.signUp) }
                }
            case .signUp:
                HStack(spacing: 4) {
                    Text("Already have an account?").foregroundStyle(.secondary)
                    Button("Sign in") { switchTo(.signIn) }
                }
            case .reset:
                Button("Back to sign in") { switchTo(.signIn) }
            }
        }
        .font(.callout)
        .buttonStyle(.plain)
        .tint(Color(hexString: "#FF6B35"))
    }

    private func switchTo(_ newMode: Mode) {
        auth.errorMessage = nil
        auth.infoMessage = nil
        mode = newMode
    }

    private func submit() {
        Task {
            switch mode {
            case .signIn: await auth.signIn(email: email, password: password)
            case .signUp: await auth.signUp(email: email, password: password)
            case .reset:  await auth.resetPassword(email: email)
            }
        }
    }
}
