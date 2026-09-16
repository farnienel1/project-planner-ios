//
//  AuthenticationView.swift
//  Project Planner
//
//  Login UI matched to LoginScreen.tsx / login.html brand design.
//

import SwiftUI
import FirebaseAuth
import UIKit

private enum LoginBrand {
    static let bgDeep = Color(red: 0.024, green: 0.055, blue: 0.102) // #060E1A
    static let bgMid = Color(red: 0.043, green: 0.094, blue: 0.157) // #0B1828
    static let bgBottom = Color(red: 0.027, green: 0.078, blue: 0.133) // #071422
    static let cyan = Color(red: 0.133, green: 0.898, blue: 1.0) // #22E5FF
    static let blue = Color(red: 0.102, green: 0.420, blue: 0.961) // #1A6BF5
    static let blueMid = Color(red: 0.055, green: 0.310, blue: 0.847) // #0E4FD8
    static let blueDark = Color(red: 0.039, green: 0.243, blue: 0.769) // #0A3EC4
    static let fieldFill = Color.white.opacity(0.05)
    static let fieldFillFocus = Color.white.opacity(0.08)
    static let borderField = Color.white.opacity(0.10)
    static let textSecondary = Color.white.opacity(0.50)
    static let textMuted = Color.white.opacity(0.25)
    static let textDim = Color.white.opacity(0.18)
}

struct AuthenticationView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @State private var email = ""
    @State private var password = ""
    @State private var showingForgotPassword = false
    @State private var showPassword = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case email, password
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [LoginBrand.bgDeep, LoginBrand.bgMid, LoginBrand.bgBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Ambient glows
            Circle()
                .fill(LoginBrand.cyan.opacity(0.12))
                .frame(width: 300, height: 300)
                .blur(radius: 60)
                .offset(y: -220)
                .allowsHitTesting(false)

            Circle()
                .fill(LoginBrand.blue.opacity(0.15))
                .frame(width: 220, height: 220)
                .blur(radius: 50)
                .offset(x: 100, y: 320)
                .allowsHitTesting(false)

            // Subtle grid texture
            loginGridOverlay
                .opacity(0.5)
                .allowsHitTesting(false)

            ScrollView {
                VStack(spacing: 0) {
                    logoSection
                        .padding(.top, 52)
                        .padding(.bottom, 44)

                    formSection
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            firebaseBackend.isLoading = false
        }
        .onSubmit {
            if focusedField == .email {
                focusedField = .password
            } else if isFormValid {
                signIn()
            }
        }
        .onChange(of: email) { _, _ in
            firebaseBackend.errorMessage = nil
            userStore.errorMessage = nil
        }
        .onChange(of: password) { _, _ in
            firebaseBackend.errorMessage = nil
            userStore.errorMessage = nil
        }
        .sheet(isPresented: $showingForgotPassword) {
            PasswordResetView(email: $email)
                .environmentObject(firebaseBackend)
        }
    }

    private var loginGridOverlay: some View {
        Canvas { context, size in
            let step: CGFloat = 40
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(Color(red: 0, green: 0.706, blue: 1).opacity(0.04)), lineWidth: 1)
        }
        .ignoresSafeArea()
    }

    private var logoSection: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.051, green: 0.106, blue: 0.180),
                                Color(red: 0.039, green: 0.082, blue: 0.145)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color(red: 0, green: 0.831, blue: 1).opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: LoginBrand.cyan.opacity(0.18), radius: 18, x: 0, y: 0)

                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
            }
            .frame(width: 88, height: 88)
            .padding(.bottom, 28)

            VStack(spacing: 2) {
                Text("PROJECT")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(.white)
                    .tracking(-0.5)
                Text("PLANNER")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(LoginBrand.cyan)
                    .tracking(-0.5)
            }
            .padding(.bottom, 10)

            Text("Built for construction teams")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LoginBrand.textSecondary)
                .tracking(1.5)
                .textCase(.uppercase)
                .padding(.top, 8)
        }
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldGroup(label: "Email") {
                LoginAutofillField(
                    text: $email,
                    placeholder: "your@email.com",
                    isSecure: false,
                    contentType: .username,
                    keyboardType: .emailAddress,
                    returnKey: .next,
                    onSubmit: { focusedField = .password }
                )
            }
            .padding(.bottom, 16)

            fieldGroup(label: "Password") {
                HStack(spacing: 0) {
                    LoginAutofillField(
                        text: $password,
                        placeholder: "Enter your password",
                        isSecure: !showPassword,
                        contentType: .password,
                        keyboardType: .default,
                        returnKey: .done,
                        onSubmit: signIn
                    )

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye" : "eye.slash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(showPassword ? LoginBrand.cyan : LoginBrand.textMuted)
                            .frame(width: 40, height: 52)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 12)

            if let errorMessage = activeErrorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color(red: 1, green: 0.235, blue: 0.235).opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(red: 1, green: 0.235, blue: 0.235).opacity(0.20), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.bottom, 12)
            }

            HStack {
                Spacer()
                Button("Forgot password?") {
                    showingForgotPassword = true
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LoginBrand.cyan.opacity(0.8))
            }
            .padding(.bottom, 28)
            .padding(.top, -4)

            Button(action: signIn) {
                ZStack {
                    if firebaseBackend.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Sign In")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    LinearGradient(
                        colors: isFormValid && !firebaseBackend.isLoading
                            ? [LoginBrand.blue, LoginBrand.blueMid, LoginBrand.blueDark]
                            : [LoginBrand.blue.opacity(0.4), LoginBrand.blueDark.opacity(0.4)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: LoginBrand.blue.opacity(isFormValid ? 0.45 : 0.15), radius: 16, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(firebaseBackend.isLoading || !isFormValid)
            .padding(.bottom, 24)

            HStack(spacing: 12) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                Text("New to Project Planner?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LoginBrand.textMuted)
                    .fixedSize()
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
            .padding(.bottom, 20)

            Button(action: { AppBranding.openOrganisationSetup() }) {
                HStack(spacing: 9) {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Set up your organisation on the web")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(LoginBrand.cyan)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(LoginBrand.cyan.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Text(versionLine)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LoginBrand.textDim)
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
        }
    }

    private func fieldGroup<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        let isFocused: Bool = {
            switch label {
            case "Email": return focusedField == .email
            case "Password": return focusedField == .password
            default: return false
            }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LoginBrand.textSecondary)
                .tracking(0.8)
                .textCase(.uppercase)

            content()
                .padding(.leading, 18)
                .frame(height: 52)
                .background(isFocused ? LoginBrand.fieldFillFocus : LoginBrand.fieldFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isFocused ? LoginBrand.cyan.opacity(0.5) : LoginBrand.borderField, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: isFocused ? LoginBrand.cyan.opacity(0.12) : .clear, radius: 12, x: 0, y: 0)
        }
    }

    private var activeErrorMessage: String? {
        if let errorMessage = firebaseBackend.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if let errorMessage = userStore.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return nil
    }

    private var versionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "v\(v) · Project Planner"
    }

    private var isFormValid: Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedEmail.isEmpty && !password.isEmpty
    }

    private func signIn() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            firebaseBackend.errorMessage = "Please enter your email address."
            return
        }
        guard !trimmedPassword.isEmpty else {
            firebaseBackend.errorMessage = "Please enter your password."
            return
        }

        userStore.errorMessage = nil
        Task { @MainActor in
            do {
                try await firebaseBackend.signIn(
                    email: trimmedEmail,
                    password: trimmedPassword
                )
                if let uid = Auth.auth().currentUser?.uid, !uid.isEmpty {
                    NotificationCenter.default.post(name: .firebaseAuthUIDChanged, object: nil, userInfo: ["uid": uid])
                }
                Task { await userStore.loadCurrentUser() }
            } catch {
                if firebaseBackend.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    firebaseBackend.errorMessage = "Sign in failed. Please check your email/password and try again."
                }
            }
        }
    }
}

/// UIKit fields so iOS Passwords / Keychain AutoFill can write into login (SwiftUI TextField + SecureField swaps often swallow the fill).
private struct LoginAutofillField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isSecure: Bool
    var contentType: UITextContentType
    var keyboardType: UIKeyboardType
    var returnKey: UIReturnKeyType
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.textColor = .white
        field.tintColor = UIColor(red: 0.133, green: 0.898, blue: 1.0, alpha: 1)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.keyboardAppearance = .dark
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.28)]
        )
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        applyChrome(to: field)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        if field.text != text {
            field.text = text
        }
        applyChrome(to: field)
    }

    private func applyChrome(to field: UITextField) {
        field.isSecureTextEntry = isSecure
        field.textContentType = contentType
        field.keyboardType = keyboardType
        field.returnKeyType = returnKey
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        @objc func editingChanged(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onSubmit()
            return true
        }
    }
}

#Preview {
    AuthenticationView()
        .environmentObject(FirebaseBackend())
        .environmentObject(UserStore())
}
