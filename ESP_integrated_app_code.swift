import SwiftUI
import CoreBluetooth
import LocalAuthentication
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn
import AuthenticationServices
import CryptoKit

// MARK: - App Colors

extension Color {
    static let tulipRed    = Color(red: 0.776, green: 0.157, blue: 0.157)   // #C62828
    static let leafGreen   = Color(red: 0.30, green: 0.55, blue: 0.30)
    static let skyTop      = Color(red: 0.55, green: 0.79, blue: 0.98)
    static let skyBottom   = Color(red: 0.88, green: 0.95, blue: 1.0)
    static let tulipYellow = Color(red: 0.98, green: 0.80, blue: 0.20)
    static let tulipPink   = Color(red: 0.95, green: 0.45, blue: 0.62)
    static let sunCore     = Color(red: 1.0, green: 0.82, blue: 0.20)
    static let sunRay      = Color(red: 1.0, green: 0.62, blue: 0.10)
    static let sunMic      = Color(red: 0.70, green: 0.33, blue: 0.0)
}

// MARK: - Voice Targets (goal set by the SLP; screen scale follows the goal)

@MainActor
enum VoiceTargets {
    /// Loudness goal in dB. Set from the SLP's plan when an exercise opens.
    static var targetDB = 70.0

    /// Anything within this many dB under the goal still counts as "in the green".
    static let toleranceDB = 3.0

    static var zoneLowDB: Double  { targetDB - toleranceDB }
    static var zoneHighDB: Double { targetDB + 7 }
    static var silenceDB: Double  { max(targetDB - 15, 45) }

    /// Maps dB to a 0...1 screen scale. The goal always sits about 2/3 of the way up.
    static func level(_ db: Double) -> Double {
        min(max((db - (targetDB - 30)) / 45, 0), 1)
    }

    static var silence: Double  { level(silenceDB) }
    static var loud: Double     { level(zoneLowDB) }
    static var loudHigh: Double { level(zoneHighDB) }
}

// MARK: - Face ID / Touch ID

enum BiometricAuth {
    static func availableLabel() -> String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }
        switch context.biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default:       return nil
        }
    }

    /// Falls back to the device passcode if Face ID fails.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

// MARK: - Big, high-contrast buttons (whole area is tappable)

struct BigButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .primary
    var height: CGFloat = 72

    func makeBody(configuration: Configuration) -> some View {
        BigButtonBody(configuration: configuration, kind: kind, height: height)
    }
}

private struct BigButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: BigButtonStyle.Kind
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        configuration.label
            .font(.title2.bold())
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(shape.fill(background))
            .overlay(shape.stroke(border, lineWidth: kind == .secondary ? 3 : 0))
            .contentShape(shape)                                   // every pixel is tappable
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var foreground: Color {
        guard isEnabled else { return Color(white: 0.35) }
        switch kind {
        case .primary:           return .white
        case .secondary, .quiet: return .tulipRed
        }
    }

    private var background: Color {
        guard isEnabled else { return Color(white: 0.86) }
        switch kind {
        case .primary:   return .tulipRed
        case .secondary: return .white
        case .quiet:     return Color.tulipRed.opacity(0.12)
        }
    }

    private var border: Color { isEnabled ? .tulipRed : Color(white: 0.7) }
}

/// Large drop-down: the whole box opens the menu.
struct BigPicker: View {
    let title: String
    let options: [Int]
    @Binding var selection: Int
    let text: (Int) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.bold())
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        if option == selection {
                            Label(text(option), systemImage: "checkmark")
                        } else {
                            Text(text(option))
                        }
                    }
                }
            } label: {
                HStack {
                    Text(text(selection)).font(.title2.bold())
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.title3.bold())
                }
                .foregroundStyle(Color.tulipRed)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.tulipRed, lineWidth: 3))
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

// MARK: - App Entry Point (only ONE @main in the whole project)

@main
struct MyAppApp: App {
    @State private var plan = TherapyPlan()

    init() {
        FirebaseApp.configure()     // needs GoogleService-Info.plist in the project
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(plan)
                .tint(.tulipRed)
                .preferredColorScheme(.light)     // white backgrounds, red buttons
                .onOpenURL { url in GIDSignIn.sharedInstance.handle(url) }   // finishes Google sign-in
        }
    }
}

// MARK: - Shared Plan (placeholder: lives only on this phone, no server yet)

@Observable
final class TherapyPlan {
    var assigned: Set<ExerciseType> = Set(ExerciseType.allCases)
    var timesPerWeek = 5
    var minutesPerDay = 15
    var targetDB = 70
    var holdSeconds = 5
    var connectedPatientCode: String?
    var completedToday: Set<ExerciseType> = []
    let myConnectCode: String = String(format: "%06d", Int.random(in: 0...999_999))

    var assignedInOrder: [ExerciseType] {
        ExerciseType.allCases.filter { assigned.contains($0) }
    }
}

func formatCode(_ code: String) -> String {
    guard code.count == 6 else { return code }
    return String(code.prefix(3)) + " " + String(code.suffix(3))
}

// MARK: - Exercises

enum ExerciseType: String, CaseIterable, Identifiable, Hashable {
    case aah, pitchGlides, counting, sentenceReading
    var id: String { rawValue }

    var title: String {
        switch self {
        case .aah:             return "Long \"Ahh\""
        case .pitchGlides:     return "Pitch Glides"
        case .counting:        return "Counting"
        case .sentenceReading: return "Reading"
        }
    }

    var subtitle: String {
        switch self {
        case .aah:             return "Hold a strong \"Ahh\""
        case .pitchGlides:     return "Slide from low to high"
        case .counting:        return "Count from 1 to 10"
        case .sentenceReading: return "Read a short story out loud"
        }
    }

    var icon: String {
        switch self {
        case .aah:             return "speaker.wave.3.fill"
        case .pitchGlides:     return "arrow.up.and.down"
        case .counting:        return "number"
        case .sentenceReading: return "text.book.closed.fill"
        }
    }

    var color: Color {
        switch self {
        case .aah:             return .tulipRed
        case .pitchGlides:     return .purple
        case .counting:        return .orange
        case .sentenceReading: return .green
        }
    }
}

// MARK: - User Role

enum UserRole: String, CaseIterable, Identifiable {
    case patient, caregiver, slp
    var id: String { rawValue }

    var title: String {
        switch self {
        case .patient:   return "I have Parkinson's"
        case .caregiver: return "I'm a Caregiver"
        case .slp:       return "I'm a Speech-Language Pathologist"
        }
    }

    var subtitle: String {
        switch self {
        case .patient:   return "I want to practice my speech exercises"
        case .caregiver: return "I help someone practice at home"
        case .slp:       return "I work with patients on their therapy"
        }
    }

    var icon: String {
        switch self {
        case .patient:   return "person.fill"
        case .caregiver: return "heart.circle.fill"
        case .slp:       return "stethoscope"
        }
    }
}

// MARK: - Accounts (Firebase: email + password, Google, Apple)

/// Turn on once the team has a paid Apple Developer account (free Personal Teams can't use Sign in with Apple).
let appleSignInEnabled = false

enum AuthFailure: LocalizedError {
    case emailNotVerified
    case noUser
    case noWindow
    case timeout
    case missingClientID
    case missingURLScheme(String)
    case missingToken

    var errorDescription: String? {
        switch self {
        case .emailNotVerified: return "Please verify your email first."
        case .noUser:          return "Please sign in again."
        case .noWindow:        return "Couldn't open the sign-in screen. Please try again."
        case .timeout:         return "That took too long. Please check your internet and try again."
        case .missingClientID: return "Google sign-in isn't set up yet (missing CLIENT_ID). Re-download GoogleService-Info.plist."
        case .missingURLScheme(let scheme):
            return "Google sign-in needs one more setting. In Xcode: target → Info → URL Types → add this URL Scheme: \(scheme)"
        case .missingToken:    return "Sign-in didn't finish. Please try again."
        }
    }
}

enum AuthService {
    /// The account already signed in on this phone (used for Face ID unlock).
    /// Email accounts only count once their email is verified; Google/Apple emails are already verified.
    static var currentUser: User? {
        guard let user = Auth.auth().currentUser else { return nil }
        let usesPassword = user.providerData.contains { $0.providerID == EmailAuthProviderID }
        return (usesPassword && !user.isEmailVerified) ? nil : user
    }

    static var currentEmail: String? { Auth.auth().currentUser?.email }

    // MARK: Email + password

    /// Creates the account, then sends the verification email.
    /// Returns an error message if the account was made but the email couldn't be sent.
    static func signUp(name: String, email: String, password: String) async throws -> String? {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        let change = result.user.createProfileChangeRequest()
        change.displayName = name
        try? await change.commitChanges()
        do {
            try await result.user.sendEmailVerification()
            return nil
        } catch {
            print("⚠️ Verification email failed:", error)
            return "Your account was created, but the email didn't send. " + message(for: error)
        }
    }

    /// Only existing accounts can sign in. Unverified accounts are stopped here.
    static func signIn(email: String, password: String) async throws {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        try await result.user.reload()
        guard Auth.auth().currentUser?.isEmailVerified == true else {
            throw AuthFailure.emailNotVerified
        }
    }

    /// Re-checks with Firebase whether the user has tapped the email link.
    static func checkVerified() async throws -> Bool {
        guard let user = Auth.auth().currentUser else { throw AuthFailure.noUser }
        try await user.reload()
        return Auth.auth().currentUser?.isEmailVerified ?? false
    }

    static func resendVerification() async throws {
        guard let user = Auth.auth().currentUser else { throw AuthFailure.noUser }
        try await user.sendEmailVerification()
    }

    static func sendPasswordReset(email: String) async throws {
        try await Auth.auth().sendPasswordReset(withEmail: email)
    }

    // MARK: Google

    @MainActor
    static func signInWithGoogle() async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else { throw AuthFailure.missingClientID }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        try checkGoogleURLScheme()       // Google's library crashes the app if this is missing
        guard let presenter = topViewController() else { throw AuthFailure.noWindow }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else { throw AuthFailure.missingToken }
        let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                       accessToken: result.user.accessToken.tokenString)
        try await Auth.auth().signIn(with: credential)
    }

    /// Confirms Info.plist → URL Types contains REVERSED_CLIENT_ID from GoogleService-Info.plist.
    static func checkGoogleURLScheme() throws {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let firebasePlist = NSDictionary(contentsOfFile: path),
              let reversed = firebasePlist["REVERSED_CLIENT_ID"] as? String else {
            throw AuthFailure.missingClientID
        }
        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        guard schemes.contains(reversed) else {
            print("⚠️ Add this URL Scheme in Xcode → target → Info → URL Types:", reversed)
            throw AuthFailure.missingURLScheme(reversed)
        }
    }

    // MARK: Apple

    /// Random one-time value that ties Apple's answer to this sign-in attempt.
    static func makeNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
            return UUID().uuidString + UUID().uuidString
        }
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func signInWithApple(_ authorization: ASAuthorization, rawNonce: String) async throws {
        guard let appleID = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = appleID.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthFailure.missingToken
        }
        let credential = OAuthProvider.appleCredential(withIDToken: idToken,
                                                       rawNonce: rawNonce,
                                                       fullName: appleID.fullName)
        try await Auth.auth().signIn(with: credential)
    }

    // MARK: Session

    static func signOut() {
        GIDSignIn.sharedInstance.signOut()
        try? Auth.auth().signOut()
    }

    private static func roleKey(_ uid: String) -> String { "role.\(uid)" }

    /// The role for this account, or nil the very first time they sign in.
    /// Checks this phone first, then the online copy (for a new phone).
    static func loadRole() async throws -> UserRole? {
        guard let uid = Auth.auth().currentUser?.uid else { throw AuthFailure.noUser }
        if let raw = UserDefaults.standard.string(forKey: roleKey(uid)),
           let role = UserRole(rawValue: raw) {
            return role
        }
        // Online copy (for a new phone). Never allowed to block sign-in:
        // if it fails or takes more than 5 seconds, just ask "Who are you?".
        do {
            let raw = try await onlineRole(uid: uid, timeout: 5)
            print("✅ Online role lookup:", raw ?? "none saved yet")
            guard let raw, let role = UserRole(rawValue: raw) else { return nil }
            UserDefaults.standard.set(raw, forKey: roleKey(uid))
            return role
        } catch {
            print("⚠️ Online role lookup failed (continuing anyway):", error)
            return nil
        }
    }

    private static func onlineRole(uid: String, timeout: Double) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                let doc = try await Firestore.firestore().collection("users").document(uid).getDocument()
                return doc.data()?["role"] as? String
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AuthFailure.timeout
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Saved once. Stored on this phone right away (so it is never asked again here)
    /// and online in the background (so it follows the account to other phones).
    static func saveRole(_ role: UserRole) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthFailure.noUser }
        UserDefaults.standard.set(role.rawValue, forKey: roleKey(user.uid))
        Firestore.firestore().collection("users").document(user.uid).setData([
            "role": role.rawValue,
            "email": user.email ?? "",
            "name": user.displayName ?? "",
            "createdAt": FieldValue.serverTimestamp()
        ], merge: true) { error in
            if let error { print("⚠️ Role saved on this phone but NOT online:", error) }
        }
    }

    /// True when the person just closed the Google/Apple sheet. Not an error worth showing.
    static func wasCancelled(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == kGIDSignInErrorDomain && ns.code == GIDSignInError.canceled.rawValue { return true }
        if ns.domain == ASAuthorizationError.errorDomain && ns.code == ASAuthorizationError.canceled.rawValue { return true }
        return false
    }

    /// Plain-language error messages.
    static func message(for error: Error) -> String {
        if let failure = error as? AuthFailure { return failure.errorDescription ?? "Something went wrong." }
        let ns = error as NSError
        if ns.domain == FirestoreErrorDomain {
            if ns.code == FirestoreErrorCode.Code.permissionDenied.rawValue {
                return "Couldn't load your account settings (permission denied). Check the Firestore rules."
            }
            if ns.code == FirestoreErrorCode.Code.unavailable.rawValue {
                return "No internet connection. Please check your Wi-Fi and try again."
            }
            return "Couldn't load your account settings. Please try again."
        }
        if ns.domain == ASAuthorizationError.errorDomain {
            return "Sign in with Apple isn't available on this build yet. Please use Google."
        }
        guard ns.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: ns.code) else {
            return "Sign-in didn't work. Please try again."
        }
        switch code {
        case .emailAlreadyInUse:
            return "An account with this email already exists. Try signing in instead."
        case .invalidEmail:
            return "That email doesn't look right. Please check it."
        case .weakPassword:
            return "Please choose a stronger password (at least 8 characters)."
        case .wrongPassword, .userNotFound, .invalidCredential:
            return "That email or password isn't right. If you're new, create an account first."
        case .accountExistsWithDifferentCredential:
            return "This email is already used with a different sign-in button. Try the other one."
        case .userDisabled:
            return "This account has been turned off. Please contact your therapist."
        case .tooManyRequests:
            return "Too many tries. Please wait a few minutes and try again."
        case .networkError:
            return "No internet connection. Please check your Wi-Fi and try again."
        case .operationNotAllowed:
            return "This sign-in option isn't turned on in Firebase yet."
        default:
            return "Sign-in didn't work. Please try again."
        }
    }

    /// The screen to show Google's sign-in sheet on top of.
    @MainActor
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Root

struct ContentView: View {
    enum Screen { case login, verifyEmail, loading, chooseRole, home }

    @State private var screen: Screen = .login
    @State private var role: UserRole?
    @State private var loginError: String?
    @State private var verifyError: String?

    var body: some View {
        Group {
            switch screen {
            case .login:
                LoginView(
                    onLoginSuccess: { Task { await routeAfterSignIn() } },
                    onNeedsVerification: { problem in
                        verifyError = problem
                        screen = .verifyEmail
                    },
                    errorFromApp: $loginError
                )
            case .verifyEmail:
                VerifyEmailView(
                    initialError: verifyError,
                    onVerified: { Task { await routeAfterSignIn() } },
                    onCancel: {
                        AuthService.signOut()
                        screen = .login
                    }
                )
            case .loading:
                VStack(spacing: 20) {
                    ProgressView().scaleEffect(2)
                    Text("Signing you in…").font(.title2.bold())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .chooseRole:
                RoleSelectionView { selected in
                    try await AuthService.saveRole(selected)
                    role = selected
                    screen = .home
                }
            case .home:
                if role == .slp {
                    SLPHomeView(onSignOut: signOut)
                } else {
                    PatientHomeView(onExit: signOut)
                }
            }
        }
        .animation(.easeInOut, value: screen)
    }

    /// First sign-in on an account asks "Who are you?". After that, it goes straight home.
    private func routeAfterSignIn() async {
        print("✅ Signed in as", AuthService.currentEmail ?? "?")
        screen = .loading
        do {
            if let saved = try await AuthService.loadRole() {
                role = saved
                screen = .home
            } else {
                screen = .chooseRole
            }
        } catch {
            print("⚠️ Couldn't finish signing in:", error)
            AuthService.signOut()
            loginError = AuthService.message(for: error)
            screen = .login
        }
    }

    private func signOut() {
        AuthService.signOut()
        role = nil
        screen = .login
    }
}

// MARK: - Login (Google / Apple, plus Face ID for a returning user)

struct LoginView: View {
    var onLoginSuccess: () -> Void = {}
    /// Called with nil, or with a message if the verification email failed to send.
    var onNeedsVerification: (String?) -> Void = { _ in }
    @Binding var errorFromApp: String?

    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var showSignUp = false
    @State private var infoMessage: String?
    @FocusState private var focusedField: Field?
    enum Field { case email, password }

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var biometryLabel: String?
    @State private var rememberedName: String?
    @State private var appleNonce = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                        .accessibilityHidden(true)
                    Text("Welcome").font(.largeTitle.bold())
                    Text("Sign in to start your speech practice")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                // Returning user on this phone: one tap with Face ID
                if let biometryLabel, let rememberedName {
                    VStack(spacing: 10) {
                        Button {
                            Task { await biometricLogin() }
                        } label: {
                            Label("Continue with \(biometryLabel)",
                                  systemImage: biometryLabel == "Touch ID" ? "touchid" : "faceid")
                        }
                        .buttonStyle(BigButtonStyle(kind: .primary, height: 84))

                        Text(rememberedName)
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        Button("Use a different account") {
                            AuthService.signOut()
                            self.rememberedName = nil
                        }
                        .buttonStyle(BigButtonStyle(kind: .quiet, height: 56))
                    }

                    HStack {
                        VStack { Divider() }
                        Text("or").font(.callout).foregroundStyle(.secondary)
                        VStack { Divider() }
                    }
                }

                Button {
                    Task { await googleLogin() }
                } label: {
                    HStack(spacing: 14) {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("G")
                                .font(.system(size: 28, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.tulipRed)
                                .accessibilityHidden(true)
                        }
                        Text(isLoading ? "Signing in…" : "Continue with Google")
                    }
                }
                .buttonStyle(BigButtonStyle(kind: .secondary, height: 80))
                .disabled(isLoading)

                if appleSignInEnabled {
                    SignInWithAppleButton(.continue) { request in
                        appleNonce = AuthService.makeNonce()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = AuthService.sha256(appleNonce)
                    } onCompletion: { result in
                        Task { await appleLogin(result) }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .disabled(isLoading)
                }

                HStack {
                    VStack { Divider() }
                    Text("or use your email").font(.callout).foregroundStyle(.secondary)
                    VStack { Divider() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Email").font(.headline)
                    TextField("you@example.com", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .email)
                        .onSubmit { focusedField = .password }
                        .modifier(LargeFieldStyle())
                        .accessibilityLabel("Email address")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Password").font(.headline)
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .onSubmit { Task { await emailLogin() } }

                        PasswordEyeButton(isShowing: $showPassword)
                    }
                    .modifier(LargeFieldStyle())
                }

                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }
                if let infoMessage {
                    InfoBanner(message: infoMessage)
                }

                Button {
                    Task { await emailLogin() }
                } label: {
                    HStack(spacing: 12) {
                        if isLoading { ProgressView().tint(.white) }
                        Text(isLoading ? "Signing in…" : "Sign In")
                    }
                }
                .buttonStyle(BigButtonStyle(kind: .primary))
                .disabled(isLoading)

                Button("Forgot password?") { Task { await forgotPassword() } }
                    .buttonStyle(BigButtonStyle(kind: .quiet, height: 56))
                    .disabled(isLoading)

                Divider().padding(.vertical, 4)

                VStack(spacing: 12) {
                    Text("New here? Tap Continue with Google, or:")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Create an Account with Email") { showSignUp = true }
                        .buttonStyle(BigButtonStyle(kind: .secondary))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showSignUp) {
            SignUpView { problem in
                showSignUp = false
                onNeedsVerification(problem)
            }
            .tint(.tulipRed)
        }
        .task {
            biometryLabel = BiometricAuth.availableLabel()
            if let user = AuthService.currentUser {
                rememberedName = user.displayName ?? user.email ?? "Your account"
            }
            if let errorFromApp {
                errorMessage = errorFromApp
                self.errorFromApp = nil
            }
        }
    }

    private func emailLogin() async {
        errorMessage = nil
        infoMessage = nil
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !password.isEmpty else {
            errorMessage = "Please enter your email and password."
            return
        }
        isLoading = true
        focusedField = nil
        defer { isLoading = false }
        do {
            try await AuthService.signIn(email: trimmed, password: password)
            password = ""
            onLoginSuccess()
        } catch AuthFailure.emailNotVerified {
            print("ℹ️ Email not verified yet:", trimmed)
            onNeedsVerification(nil)
        } catch {
            print("⚠️ Email sign-in failed:", error)
            errorMessage = AuthService.message(for: error)
        }
    }

    private func forgotPassword() async {
        errorMessage = nil
        infoMessage = nil
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("@") else {
            errorMessage = "Type your email above, then tap \"Forgot password?\" again."
            focusedField = .email
            return
        }
        do {
            try await AuthService.sendPasswordReset(email: trimmed)
            infoMessage = "If an account exists for \(trimmed), we sent a reset link. Check your inbox and spam folder."
        } catch {
            errorMessage = AuthService.message(for: error)
        }
    }

    private func googleLogin() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await AuthService.signInWithGoogle()
            onLoginSuccess()
        } catch {
            if !AuthService.wasCancelled(error) { errorMessage = AuthService.message(for: error) }
        }
    }

    private func appleLogin(_ result: Result<ASAuthorization, Error>) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let authorization = try result.get()
            try await AuthService.signInWithApple(authorization, rawNonce: appleNonce)
            onLoginSuccess()
        } catch {
            if !AuthService.wasCancelled(error) { errorMessage = AuthService.message(for: error) }
        }
    }

    /// Face ID only unlocks an account that is already signed in on this phone.
    private func biometricLogin() async {
        errorMessage = nil
        guard let user = AuthService.currentUser else {
            rememberedName = nil
            return
        }
        guard await BiometricAuth.authenticate(reason: "Sign in to your speech practice") else {
            errorMessage = "\(biometryLabel ?? "Face ID") didn't work. Try again or sign in below."
            return
        }
        do {
            _ = try await user.getIDToken(forcingRefresh: true)   // checks the account still exists
            onLoginSuccess()
        } catch {
            AuthService.signOut()
            rememberedName = nil
            errorMessage = "Please sign in again."
        }
    }
}

struct PasswordEyeButton: View {
    @Binding var isShowing: Bool

    var body: some View {
        Button { isShowing.toggle() } label: {
            Image(systemName: isShowing ? "eye.slash.fill" : "eye.fill")
                .font(.title2)
                .foregroundStyle(Color.tulipRed)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isShowing ? "Hide password" : "Show password")
    }
}


// MARK: - Sign Up

struct SignUpView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showPassword = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// Called after the account is created. Passes a message if the verification email failed.
    var onSignUpSuccess: (String?) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Create Your Account")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 32)

                field("Your name") {
                    TextField("First name", text: $name)
                        .textContentType(.givenName)
                }

                field("Email") {
                    TextField("you@example.com", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                field("Password (at least 8 characters)") {
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.newPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        PasswordEyeButton(isShowing: $showPassword)
                    }
                }

                field("Type password again") {
                    Group {
                        if showPassword {
                            TextField("Password", text: $confirmPassword)
                        } else {
                            SecureField("Password", text: $confirmPassword)
                        }
                    }
                    .textContentType(.newPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                Button {
                    Task { await signUp() }
                } label: {
                    HStack(spacing: 12) {
                        if isLoading { ProgressView().tint(.white) }
                        Text(isLoading ? "Creating account…" : "Create Account")
                    }
                }
                .buttonStyle(BigButtonStyle(kind: .primary))
                .disabled(isLoading)

                Button("Cancel") { dismiss() }
                    .buttonStyle(BigButtonStyle(kind: .quiet, height: 60))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .interactiveDismissDisabled(isLoading)
    }

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline)
            content().modifier(LargeFieldStyle())
        }
    }

    private func signUp() async {
        errorMessage = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            errorMessage = "Please enter your name."; return
        }
        guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
            errorMessage = "That email doesn't look right. Please check it."; return
        }
        guard password.count >= 8 else {
            errorMessage = "Password needs at least 8 characters."; return
        }
        guard password == confirmPassword else {
            errorMessage = "The two passwords don't match."; return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let problem = try await AuthService.signUp(name: trimmedName, email: trimmedEmail, password: password)
            onSignUpSuccess(problem)
        } catch {
            errorMessage = AuthService.message(for: error)
        }
    }
}

// MARK: - Verify Email

struct VerifyEmailView: View {
    var initialError: String? = nil
    var onVerified: () -> Void = {}
    var onCancel: () -> Void = {}

    @State private var isChecking = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var resendWait = 0

    private let email = AuthService.currentEmail ?? "your email"

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(Color.tulipRed)
                    .padding(.top, 48)
                    .accessibilityHidden(true)

                Text("Check your email")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                VStack(spacing: 8) {
                    Text("We sent a link to")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(email)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Open the email from us.")
                    step(2, "Tap the link inside it.")
                    step(3, "Come back here and tap the red button.")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                Text("Can't find it? Check your spam or junk folder. It comes from noreply@…firebaseapp.com and can take a few minutes.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let errorMessage { ErrorBanner(message: errorMessage) }
                if let infoMessage { InfoBanner(message: infoMessage) }

                Button {
                    Task { await check() }
                } label: {
                    HStack(spacing: 12) {
                        if isChecking { ProgressView().tint(.white) }
                        Text(isChecking ? "Checking…" : "I've Verified My Email")
                    }
                }
                .buttonStyle(BigButtonStyle(kind: .primary, height: 84))
                .disabled(isChecking)

                Button(resendWait > 0 ? "Send Again (wait \(resendWait)s)" : "Send the Email Again") {
                    Task { await resend() }
                }
                .buttonStyle(BigButtonStyle(kind: .secondary))
                .disabled(resendWait > 0)

                Button("Back to Sign In", action: onCancel)
                    .buttonStyle(BigButtonStyle(kind: .quiet, height: 60))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .task { if errorMessage == nil { errorMessage = initialError } }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.tulipRed))
            Text(text).font(.title3)
            Spacer(minLength: 0)
        }
    }

    private func check() async {
        errorMessage = nil
        infoMessage = nil
        isChecking = true
        defer { isChecking = false }
        do {
            if try await AuthService.checkVerified() {
                onVerified()
            } else {
                errorMessage = "Not verified yet. Tap the link in the email first, then try again."
            }
        } catch {
            errorMessage = AuthService.message(for: error)
        }
    }

    private func resend() async {
        errorMessage = nil
        infoMessage = nil
        do {
            try await AuthService.resendVerification()
            infoMessage = "Sent! Check your email again."
            resendWait = 60
            while resendWait > 0 {
                try? await Task.sleep(for: .seconds(1))
                resendWait -= 1
            }
        } catch {
            errorMessage = AuthService.message(for: error)
        }
    }
}

/// Green confirmation box (for "email sent" messages).
struct InfoBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(message)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.green, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Role Selection

struct RoleSelectionView: View {
    @State private var selected: UserRole?
    @State private var isSaving = false
    @State private var errorMessage: String?
    var onContinue: (UserRole) async throws -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Who are you?")
                        .font(.largeTitle.bold())
                    Text("Choose the one that fits you best. You'll only be asked once.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)
                .padding(.bottom, 8)

                ForEach(UserRole.allCases) { role in
                    RoleCard(role: role, isSelected: selected == role) {
                        selected = role
                    }
                }

                if let errorMessage { ErrorBanner(message: errorMessage) }

                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 12) {
                        if isSaving { ProgressView().tint(.white) }
                        Text(isSaving ? "Saving…" : "Continue")
                    }
                }
                .buttonStyle(BigButtonStyle(kind: .primary))
                .disabled(selected == nil || isSaving)
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private func save() async {
        guard let selected else { return }
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await onContinue(selected)
        } catch {
            errorMessage = AuthService.message(for: error)
        }
    }
}

struct RoleCard: View {
    let role: UserRole
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: role.icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.tulipRed)
                    .frame(width: 64, height: 64)
                    .background(isSelected ? Color.tulipRed : Color.tulipRed.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(role.title)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(role.subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title)
                    .foregroundStyle(isSelected ? Color.tulipRed : Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(isSelected ? Color.tulipRed : Color.clear, lineWidth: 3))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - SLP Home

struct SLPHomeView: View {
    @Environment(TherapyPlan.self) private var plan
    var onSignOut: () -> Void = {}

    @State private var codeInput = ""
    @State private var codeError: String?
    @State private var showPreview = false
    @State private var savedMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Clinician Dashboard").font(.largeTitle.bold())
                    Text("Set up your patient's home practice")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                SectionCard(title: "Connect Patient", icon: "link") {
                    if let code = plan.connectedPatientCode {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connected").font(.title3.bold())
                                Text("Patient code \(formatCode(code))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Disconnect") { plan.connectedPatientCode = nil }
                            .buttonStyle(BigButtonStyle(kind: .secondary, height: 60))
                    } else {
                        Text("Enter the 6-digit code shown in your patient's app.")
                            .foregroundStyle(.secondary)
                        TextField("123456", text: $codeInput)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(.title2.monospacedDigit())
                            .modifier(LargeFieldStyle())
                            .onChange(of: codeInput) { _, new in
                                let cleaned = String(new.filter(\.isNumber).prefix(6))
                                if cleaned != new { codeInput = cleaned }
                            }
                            .accessibilityLabel("Patient code")
                        if let codeError { ErrorBanner(message: codeError) }
                        Button("Connect", action: connect)
                            .buttonStyle(BigButtonStyle(kind: .primary))
                    }
                }

                SectionCard(title: "Exercises", icon: "checklist") {
                    Text("Select all that apply")
                        .foregroundStyle(.secondary)
                    ForEach(ExerciseType.allCases) { ex in
                        CheckboxRow(exercise: ex, isOn: plan.assigned.contains(ex)) {
                            if plan.assigned.contains(ex) {
                                plan.assigned.remove(ex)
                            } else {
                                plan.assigned.insert(ex)
                            }
                        }
                    }
                }

                ScheduleSection(plan: plan)

                if let savedMessage {
                    Label(savedMessage, systemImage: "checkmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button("Save Plan") {
                    if let code = plan.connectedPatientCode {
                        savedMessage = "Plan sent to patient \(formatCode(code))"
                    }
                }
                .buttonStyle(BigButtonStyle(kind: .primary))
                .disabled(plan.connectedPatientCode == nil || plan.assigned.isEmpty)

                if plan.connectedPatientCode == nil {
                    Text("Connect a patient to send this plan.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                Button { showPreview = true } label: {
                    Label("Preview Patient View", systemImage: "eye.fill")
                }
                .buttonStyle(BigButtonStyle(kind: .secondary))

                Button("Sign Out", action: onSignOut)
                    .buttonStyle(BigButtonStyle(kind: .quiet, height: 60))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: plan.assigned) { savedMessage = nil }
        .onChange(of: plan.timesPerWeek) { savedMessage = nil }
        .onChange(of: plan.minutesPerDay) { savedMessage = nil }
        .onChange(of: plan.targetDB) { savedMessage = nil }
        .onChange(of: plan.holdSeconds) { savedMessage = nil }
        .fullScreenCover(isPresented: $showPreview) {
            PatientHomeView(isPreview: true) { showPreview = false }
                .environment(plan)
                .tint(.tulipRed)
        }
    }

    private func connect() {
        codeError = nil
        guard codeInput.count == 6 else {
            codeError = "The code should be 6 digits."
            return
        }
        // TODO: verify the code with a real server
        plan.connectedPatientCode = codeInput
        codeInput = ""
    }
}

struct ScheduleSection: View {
    @Bindable var plan: TherapyPlan

    var body: some View {
        SectionCard(title: "Practice Plan", icon: "calendar") {
            BigPicker(title: "Times per week",
                      options: Array(1...7),
                      selection: $plan.timesPerWeek) { $0 == 1 ? "1 time" : "\($0) times" }

            BigPicker(title: "Minutes per day",
                      options: [5, 10, 15, 20, 30, 45, 60],
                      selection: $plan.minutesPerDay) { "\($0) minutes" }

            BigPicker(title: "Loudness goal",
                      options: [55, 60, 65, 70, 75, 80, 85, 90],
                      selection: $plan.targetDB) { "\($0) dB" }

            BigPicker(title: "\"Ahh\" hold time",
                      options: [3, 5, 8, 10, 15],
                      selection: $plan.holdSeconds) { "\($0) seconds" }
        }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.title2.bold())
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct CheckboxRow: View {
    let exercise: ExerciseType
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 34))
                    .foregroundStyle(isOn ? Color.tulipRed : Color(.tertiaryLabel))
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.title).font(.title3.bold()).foregroundStyle(.primary)
                    Text(exercise.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 72)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(isOn ? Color.tulipRed : Color(.separator), lineWidth: isOn ? 3 : 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Patient Home

struct PatientHomeView: View {
    @Environment(TherapyPlan.self) private var plan
    var isPreview = false
    var onExit: () -> Void = {}

    var body: some View {
        let assigned = plan.assignedInOrder
        let doneCount = assigned.filter { plan.completedToday.contains($0) }.count

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if isPreview {
                        VStack(spacing: 12) {
                            Label("Preview mode: this is what your patient sees",
                                  systemImage: "eye.fill")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Button("Exit Preview", action: onExit)
                                .buttonStyle(BigButtonStyle(kind: .secondary, height: 60))
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(Color.tulipRed)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hello!").font(.largeTitle.bold())
                        Text("Ready for today's practice?")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Today: \(doneCount) of \(assigned.count) done")
                            .font(.title3.bold())
                        ProgressView(value: Double(doneCount), total: Double(max(assigned.count, 1)))
                            .scaleEffect(x: 1, y: 3, anchor: .center)
                            .padding(.vertical, 6)
                        Text("Goal: \(plan.timesPerWeek) days a week, \(plan.minutesPerDay) minutes a day")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .accessibilityElement(children: .combine)

                    Text("Exercises").font(.title2.bold())

                    if assigned.isEmpty {
                        Text("Your therapist hasn't assigned any exercises yet.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(assigned) { ex in
                        NavigationLink(value: ex) {
                            ExerciseTile(exercise: ex, isDone: plan.completedToday.contains(ex))
                        }
                        .buttonStyle(.plain)
                    }

                    if !isPreview {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your therapist code").font(.headline)
                            Text(formatCode(plan.myConnectCode))
                                .font(.system(size: 36, weight: .bold, design: .monospaced))
                            Text("Give this code to your speech therapist to connect.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .accessibilityElement(children: .combine)

                        Button("Sign Out", action: onExit)
                            .buttonStyle(BigButtonStyle(kind: .quiet, height: 60))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .navigationDestination(for: ExerciseType.self) { ex in
                ExerciseScreen(exercise: ex)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct ExerciseTile: View {
    let exercise: ExerciseType
    var isDone = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: exercise.icon)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(exercise.color)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(exercise.title).font(.title2.bold())
                Text(exercise.subtitle).font(.body).foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: isDone ? "checkmark.circle.fill" : "chevron.right.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(isDone ? Color.green : Color.tulipRed)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(minHeight: 104)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.tulipRed, lineWidth: 2.5))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done today" : "")
        .accessibilityHint("Opens the exercise")
    }
}

// MARK: - Exercise Screen (big Back button + sun microphone, then setup → exercise)

struct ExerciseScreen: View {
    let exercise: ExerciseType
    @Environment(TherapyPlan.self) private var plan
    @Environment(\.dismiss) private var dismiss
    @State private var audio = AudioMonitor()
    @State private var isReady = false
    @State private var continueAnyway = false

    var body: some View {
        Group {
            if !isReady {
                SetupCheckView(title: exercise.title) { isReady = true }
            } else if audio.noiseFloorDBFS == nil {
                if audio.isListening {
                    NoiseCheckView(progress: audio.noiseProgress)
                } else {
                    MicConnectingView(status: audio.statusText)
                }
            } else if audio.tooNoisy && !continueAnyway {
                TooNoisyView(
                    onTryAgain: { Task { await audio.measureNoise() } },
                    onContinue: { continueAnyway = true }
                )
            } else {
                switch exercise {
                case .aah:
                    AahExerciseView(audio: audio, holdGoal: Double(plan.holdSeconds)) {
                        plan.completedToday.insert(.aah)
                    }
                case .pitchGlides:
                    PitchExerciseView(audio: audio) { plan.completedToday.insert(.pitchGlides) }
                case .counting:
                    CountExerciseView(audio: audio) { plan.completedToday.insert(.counting) }
                case .sentenceReading:
                    ReadExerciseView(audio: audio) { plan.completedToday.insert(.sentenceReading) }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(alignment: .center) {
                Button { dismiss() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(BigButtonStyle(kind: .secondary, height: 60))
                .frame(width: 150)

                Spacer()

                // The microphone indicator IS the sun
                SunMicBadge(isListening: audio.isListening, level: audio.level, micName: audio.micName)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .overlay {
            // Shown only if the ESP32 drops mid-exercise; the exercise resumes once it reconnects.
            if audio.noiseFloorDBFS != nil && !audio.isListening {
                VStack(spacing: 16) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 60))
                    Text("Lost the ESP32 mic")
                        .font(.title3.weight(.semibold))
                    Text(audio.statusText)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
        }
        .onAppear { VoiceTargets.targetDB = Double(plan.targetDB) }
        .task(id: isReady) {
            if isReady { audio.start() }
        }
        .task(id: audio.isListening) {
            // Measure the room once, when the ESP32 first starts streaming.
            if audio.isListening && audio.noiseFloorDBFS == nil {
                await audio.measureNoise()
            }
        }
        .onDisappear { audio.stop() }
    }
}

/// Shown for ~2 seconds while the app listens to the room.
struct NoiseCheckView: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "ear.fill")
                .font(.system(size: 80))
                .foregroundStyle(Color.tulipRed)
                .accessibilityHidden(true)
            Text("Stay quiet for a moment")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Listening to the room so background noise doesn't count.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView(value: progress)
                .tint(Color.tulipRed)
                .scaleEffect(x: 1, y: 4, anchor: .center)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            Spacer()
            Spacer()
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

/// Shown until the ESP32 microphone is connected and streaming.
struct MicConnectingView: View {
    let status: String

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 70))
                .foregroundStyle(Color.tulipRed)
                .accessibilityHidden(true)
            Text("Connecting to your ESP32 mic")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(status)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
                .controlSize(.large)
            Spacer()
            Spacer()
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

/// Shown when the room is too loud to measure the voice reliably.
struct TooNoisyView: View {
    var onTryAgain: () -> Void
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 70))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("It's a bit noisy here")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Turn off the TV, radio, or fan, or move to a quieter room. Then try again.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Check Again", action: onTryAgain)
                .buttonStyle(BigButtonStyle(kind: .primary, height: 80))
            Button("Continue Anyway", action: onContinue)
                .buttonStyle(BigButtonStyle(kind: .secondary))
        }
        .padding(24)
    }
}

/// A sun with a microphone in the middle. Its rays grow with the voice.
struct SunMicBadge: View {
    let isListening: Bool
    let level: Double
    var micName: String = ""

    var body: some View {
        let glow = isListening ? level : 0
        ZStack {
            ForEach(0..<10, id: \.self) { i in
                Capsule()
                    .fill(Color.sunRay)
                    .frame(width: 5, height: 9 + 10 * glow)
                    .offset(y: -(25 + 4 * glow))
                    .rotationEffect(.degrees(Double(i) * 36))
            }
            Circle()
                .fill(RadialGradient(colors: [Color.sunCore, Color.sunRay],
                                     center: .center, startRadius: 2, endRadius: 24))
                .frame(width: 42, height: 42)
            Image(systemName: isListening ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.sunMic)
        }
        .frame(width: 76, height: 76)
        .opacity(isListening ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isListening ? "Microphone on: \(micName)" : "Microphone off")
    }
}

struct SetupCheckView: View {
    let title: String
    var onReady: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text(title).font(.title2.bold()).foregroundStyle(Color.tulipRed)
                    Text("Before you start").font(.largeTitle.bold())
                }
                .padding(.top, 8)

                setupRow(icon: "speaker.slash.fill",
                         title: "Are you in a quiet spot?",
                         detail: "Turn off the TV, radio, or fan.")

                setupRow(icon: "antenna.radiowaves.left.and.right",
                         title: "Is the ESP32 mic on?",
                         detail: "Power it on. The app connects to it automatically over Bluetooth.")

                setupRow(icon: "mic.fill",
                         title: "Mic about 18 inches away?",
                         detail: "Keep the ESP32 mic the same distance every time.")

                Button("I'm Ready", action: onReady)
                    .buttonStyle(BigButtonStyle(kind: .primary, height: 84))
                    .padding(.top, 8)
            }
            .padding(24)
        }
    }

    private func setupRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Color.tulipRed)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                Text(detail).font(.title3).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Microphone (ESP32 over Bluetooth LE, same protocol as ESP32BLETestApp.swift)

/// Events from the ESP32 mic. They come from the Bluetooth queue, not the main thread.
nonisolated enum MicEvent: Sendable {
    case status(String)
    case streaming(Bool)
    /// `db` = estimated dB (dBFS + 107). `pitchHz` = 0 when there is no clear voice pitch.
    case frame(db: Double, pitchHz: Double)
}

/// Finds the ESP32 "MicDB" over Bluetooth LE, rebuilds its audio packets into frames, and measures each frame.
nonisolated final class ESP32MicReceiver: NSObject, @unchecked Sendable {
    private nonisolated struct FrameAssembly {
        let sampleCount: Int
        let sampleRate: Int
        var samples: [Int16]
        var received: [Bool]

        var isComplete: Bool { received.allSatisfy { $0 } }
    }

    private let emit: @Sendable (MicEvent) -> Void
    private let queue = DispatchQueue(label: "esp32.ble", qos: .userInitiated)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var wantsConnection = false
    private var frames: [UInt16: FrameAssembly] = [:]
    private var pitchHistory: [Double] = []
    private var invalidPitchFrames = 0

    // DFT tables for the current frame size (the ESP sends 512-sample frames)
    private var tableCount = 0
    private var cosTable: [Double] = []
    private var sinTable: [Double] = []
    private var hannWindow: [Double] = []
    private var bandPowerGain: [Double] = []

    private let peripheralName = "MicDB"
    private let serviceUUID = CBUUID(string: "6e400001-a1b2-4c3d-9e8f-0123456789ab")
    private let audioUUID = CBUUID(string: "6e400002-a1b2-4c3d-9e8f-0123456789ab")
    private let errorsUUID = CBUUID(string: "6e400003-a1b2-4c3d-9e8f-0123456789ab")
    private let sampleRate = 8_000.0
    private let splCalibrationOffsetDB = 107.0
    private let frequencyAverageWindow = 7
    private let minVoiceFrequency = 60.0
    private let maxVoiceFrequency = 1_200.0
    private let yinThreshold = 0.30

    init(emit: @escaping @Sendable (MicEvent) -> Void) {
        self.emit = emit
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    /// Keeps looking for MicDB and reconnecting until `stop()`. Safe to call from any thread.
    func start() {
        queue.async {
            self.wantsConnection = true
            self.scanIfReady()
        }
    }

    func stop() {
        queue.async {
            self.wantsConnection = false
            self.central.stopScan()
            if let peripheral = self.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
            self.peripheral = nil
            self.resetStream()
            self.emit(.streaming(false))
        }
    }

    private func scanIfReady() {
        guard wantsConnection, central.state == .poweredOn, peripheral == nil else { return }
        emit(.status("Looking for \(peripheralName)..."))
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    private func retryScan() {
        queue.asyncAfter(deadline: .now() + 1.5) { self.scanIfReady() }
    }

    private func resetStream() {
        frames.removeAll()
        pitchHistory.removeAll()
        invalidPitchFrames = 0
    }

    private func handleAudioPacket(_ data: Data) {
        guard data.count >= 8 else { return }

        let frameID = data.micUInt16LE(at: 0)
        let offset = Int(data.micUInt16LE(at: 2))
        let sampleCount = Int(data.micUInt16LE(at: 4))
        let sampleRate = data.micUInt16LE(at: 6)
        let sampleBytes = data.count - 8

        guard sampleCount > 0, sampleBytes.isMultiple(of: 2) else { return }
        let packetSampleCount = sampleBytes / 2
        guard offset >= 0, offset + packetSampleCount <= sampleCount else { return }

        var frame = frames.removeValue(forKey: frameID) ?? FrameAssembly(
            sampleCount: sampleCount,
            sampleRate: Int(sampleRate),
            samples: Array(repeating: 0, count: sampleCount),
            received: Array(repeating: false, count: sampleCount)
        )
        guard frame.sampleCount == sampleCount, frame.sampleRate == Int(sampleRate) else { return }

        for sampleIndex in 0..<packetSampleCount {
            frame.samples[offset + sampleIndex] = Int16(
                bitPattern: data.micUInt16LE(at: 8 + sampleIndex * 2)
            )
            frame.received[offset + sampleIndex] = true
        }

        if frame.isComplete {
            let db = measureAWeightedDB(samples: frame.samples)
            let pitch = estimatePitch(samples: frame.samples)
            if pitch > 0 {
                pitchHistory.append(pitch)
                if pitchHistory.count > frequencyAverageWindow {
                    pitchHistory.removeFirst()
                }
                invalidPitchFrames = 0
            } else {
                invalidPitchFrames += 1
                if invalidPitchFrames >= 3 {
                    pitchHistory.removeAll()
                }
            }
            let averagePitch = pitchHistory.isEmpty
                ? 0
                : pitchHistory.reduce(0, +) / Double(pitchHistory.count)
            emit(.frame(db: db, pitchHz: averagePitch))
        } else {
            frames[frameID] = frame
        }

        while frames.count > 8 {
            frames.removeValue(forKey: frames.keys.min()!)
        }
    }

    private func prepareTables(count: Int) {
        guard count != tableCount else { return }
        tableCount = count
        let n = Double(count)
        cosTable = (0..<count).map { cos(2.0 * Double.pi * Double($0) / n) }
        sinTable = (0..<count).map { sin(2.0 * Double.pi * Double($0) / n) }
        hannWindow = (0..<count).map { 0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / (n - 1)) }
        bandPowerGain = (0...(count / 2)).map { bin -> Double in
            let frequency = Double(bin) * sampleRate / n
            let frequencySquared = max(frequency, 1.0e-12) * max(frequency, 1.0e-12)
            let numerator: Double = pow(12_194.0, 2.0) * pow(frequencySquared, 2.0)
            let denominator: Double = (frequencySquared + pow(20.6, 2.0))
                * sqrt((frequencySquared + pow(107.7, 2.0)) * (frequencySquared + pow(737.9, 2.0)))
                * (frequencySquared + pow(12_194.0, 2.0))
            let ra = denominator > 0.0 ? numerator / denominator : 0.0
            let weighting = ra > 0.0 ? pow(10.0, (20.0 * log10(ra) + 2.0) / 20.0) : 0.0
            let multiplier = (bin > 0 && bin < count / 2) ? 2.0 : 1.0
            return weighting * weighting * multiplier
        }
    }

    /// A-weighted level in dB (dBFS + 107), the same calculation as ESP32BLETestApp.swift.
    private func measureAWeightedDB(samples: [Int16]) -> Double {
        let count = samples.count
        guard count > 1 else { return 0 }
        prepareTables(count: count)

        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(count)
        let windowed = (0..<count).map { (Double(samples[$0]) - mean) * hannWindow[$0] }

        var weightedPower = 0.0
        for bin in 0...(count / 2) {
            var real = 0.0
            var imaginary = 0.0
            for index in 0..<count {
                let angleIndex = (bin * index) % count
                real += windowed[index] * cosTable[angleIndex]
                imaginary -= windowed[index] * sinTable[angleIndex]
            }
            weightedPower += (real * real + imaginary * imaginary) * bandPowerGain[bin]
        }

        let windowPower = windowed.reduce(0.0) { $0 + $1 * $1 }
        let meanSquare = windowPower > 0 ? weightedPower / (Double(count) * windowPower) : 0
        let rms = sqrt(max(meanSquare, 0))
        let fullScaleSineRMS = 32_768.0 / sqrt(2.0)
        let dbfs = 20.0 * log10(max(rms, 1.0) / fullScaleSineRMS)
        return dbfs + splCalibrationOffsetDB
    }

    private func estimatePitch(samples: [Int16]) -> Double {
        let count = samples.count
        guard count > 0 else { return 0.0 }

        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(count)
        let meanRemoved = samples.map { Double($0) - mean }
        let highpassCutoff = 80.0
        let w0 = 2.0 * Double.pi * highpassCutoff / sampleRate
        let alpha = sin(w0) / (2.0 * 0.7071)
        let cosw = cos(w0)
        let a0 = 1.0 + alpha
        let b0 = (1.0 + cosw) / 2.0 / a0
        let b1 = -(1.0 + cosw) / a0
        let b2 = b0
        let a1 = -2.0 * cosw / a0
        let a2 = (1.0 - alpha) / a0

        var filtered = Array(repeating: 0.0, count: count)
        var x1 = 0.0
        var x2 = 0.0
        var y1 = 0.0
        var y2 = 0.0

        for index in 0..<count {
            let x0 = meanRemoved[index]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            filtered[index] = y0
            x2 = x1
            x1 = x0
            y2 = y1
            y1 = y0
        }

        let minLag = max(1, Int(sampleRate / maxVoiceFrequency))
        let maxLag = min(count - 1, Int(sampleRate / minVoiceFrequency))
        guard minLag <= maxLag else { return 0.0 }

        var cmnd = Array(repeating: 1.0, count: maxLag + 1)
        var runningSum = 0.0

        for lag in 1...maxLag {
            var difference = 0.0
            for index in 0..<(count - lag) {
                let delta = filtered[index] - filtered[index + lag]
                difference += delta * delta
            }

            runningSum += difference
            if runningSum > 1.0e-12 {
                cmnd[lag] = difference * Double(lag) / runningSum
            }
        }

        var selectedLag: Int?
        var lag = minLag
        while lag <= maxLag {
            if cmnd[lag] < yinThreshold {
                while lag < maxLag && cmnd[lag + 1] < cmnd[lag] {
                    lag += 1
                }
                selectedLag = lag
                break
            }
            lag += 1
        }

        guard let selectedLag else { return 0.0 }

        var refinedLag = Double(selectedLag)
        if selectedLag > 1 && selectedLag < maxLag {
            let left = cmnd[selectedLag - 1]
            let center = cmnd[selectedLag]
            let right = cmnd[selectedLag + 1]
            let denominator = left - 2.0 * center + right
            if abs(denominator) > 1.0e-12 {
                let correction = 0.5 * (left - right) / denominator
                refinedLag += max(-1.0, min(1.0, correction))
            }
        }

        guard refinedLag > 0.0 else { return 0.0 }

        let frequency = sampleRate / refinedLag
        return frequency >= minVoiceFrequency && frequency <= maxVoiceFrequency
            ? frequency
            : 0.0
    }

    // MARK: CBCentralManagerDelegate (runs on `queue`)

    fileprivate func handleBluetoothState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            scanIfReady()
        case .poweredOff:
            resetStream()
            emit(.streaming(false))
            emit(.status("Turn on Bluetooth to hear the ESP32 mic."))
        case .unauthorized:
            emit(.status("Allow Bluetooth for this app in Settings."))
        case .unsupported:
            emit(.status("Bluetooth Low Energy isn't supported on this device."))
        case .resetting:
            emit(.status("Bluetooth is resetting..."))
        case .unknown:
            emit(.status("Starting Bluetooth..."))
        @unknown default:
            emit(.status("Bluetooth isn't available."))
        }
    }
}

private extension Data {
    nonisolated func micUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
}

extension ESP32MicReceiver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleBluetoothState(central.state)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.peripheral == nil, peripheral.name == peripheralName else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        emit(.status("Found \(peripheralName); connecting..."))
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit(.status("Connected; finding the audio service..."))
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        self.peripheral = nil
        emit(.status("Couldn't connect to \(peripheralName); retrying..."))
        retryScan()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        self.peripheral = nil
        resetStream()
        emit(.streaming(false))
        emit(.status("\(peripheralName) disconnected; reconnecting..."))
        retryScan()
    }
}

extension ESP32MicReceiver: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            emit(.status("\(peripheralName) doesn't have the audio service."))
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([audioUUID, errorsUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let characteristics = service.characteristics,
              characteristics.contains(where: { $0.uuid == audioUUID }) else {
            emit(.status("\(peripheralName) doesn't have the audio characteristic."))
            central.cancelPeripheralConnection(peripheral)
            return
        }
        for characteristic in characteristics where characteristic.uuid == audioUUID || characteristic.uuid == errorsUUID {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        emit(.status("Connected; waiting for audio..."))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == audioUUID else { return }
        guard error == nil, characteristic.isNotifying else {
            emit(.status("Couldn't turn on audio from \(peripheralName)."))
            central.cancelPeripheralConnection(peripheral)
            return
        }
        emit(.status("Streaming from \(peripheralName)."))
        emit(.streaming(true))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, characteristic.uuid == audioUUID, let data = characteristic.value else { return }
        handleAudioPacket(data)
    }
}

@MainActor
@Observable
final class AudioMonitor {
    var db: Double = 0             // estimated dB (approximate: not calibrated)
    var dbfs: Double = -100        // raw mic level
    var pitch: Double = 0          // Hz from the ESP32, 0 when no clear pitch
    var tick = 0                   // increments for every audio frame from the ESP32 (~15 per second)
    var isListening = false        // true while audio is streaming from the ESP32
    var statusText = "Starting Bluetooth..."
    let micName = "ESP32 mic (MicDB)"
    private let offset: Double = 107   // dB = dBFS + offset (same calibration as ESP32BLETestApp.swift)

    // Background-noise check (runs before every exercise)
    var noiseFloorDBFS: Double?    // nil = not measured yet
    var isMeasuringNoise = false
    var noiseProgress: Double = 0
    var tooNoisy = false
    @ObservationIgnored private var noiseSamples: [Double] = []

    /// 0...1 screen scale used by the visuals.
    var level: Double { VoiceTargets.level(db) }

    @ObservationIgnored private var receiver: ESP32MicReceiver?

    func start() {
        guard receiver == nil else { return }
        receiver = ESP32MicReceiver { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        receiver?.start()
    }

    func stop() {
        receiver?.stop()
        receiver = nil
        isListening = false
        dbfs = -100
        db = 0
        pitch = 0
    }

    private func handle(_ event: MicEvent) {
        guard receiver != nil else { return }
        switch event {
        case .status(let text):
            statusText = text
        case .streaming(let streaming):
            isListening = streaming
            if !streaming {
                dbfs = -100
                db = 0
                pitch = 0
            }
        case .frame(let frameDB, let hz):
            updateLevel(frameDB - offset)
            updatePitch(hz)
        }
    }

    /// Listens to the room for a moment (user stays quiet) to learn the background noise level.
    func measureNoise(seconds: Double = 2) async {
        noiseFloorDBFS = nil
        noiseSamples = []
        tooNoisy = false
        noiseProgress = 0
        isMeasuringNoise = true
        let steps = 20
        for i in 1...steps {
            try? await Task.sleep(for: .seconds(seconds / Double(steps)))
            noiseProgress = Double(i) / Double(steps)
        }
        isMeasuringNoise = false

        guard !noiseSamples.isEmpty else { noiseFloorDBFS = -80; return }
        // Use the loud end of the background (80th percentile) so fans, hum,
        // and small bumps all stay below the line.
        let sorted = noiseSamples.sorted()
        let floor = sorted[min(Int(Double(sorted.count) * 0.8), sorted.count - 1)]
        noiseFloorDBFS = floor
        // The room is too loud if its noise is within 12 dB of the goal.
        tooNoisy = floor + offset > VoiceTargets.targetDB - 12
        dbfs = -100
        db = 0
    }

    private func updateLevel(_ rawDBFS: Double) {
        if isMeasuringNoise {
            noiseSamples.append(rawDBFS)
            tick &+= 1
            return
        }

        // Remove the background noise before calculating loudness
        var voiceDBFS = rawDBFS
        if let noise = noiseFloorDBFS {
            if rawDBFS < noise + 6 {
                voiceDBFS = -100                              // just background: treat as silence
            } else {
                let total = pow(10, rawDBFS / 10)
                let background = pow(10, noise / 10)
                voiceDBFS = 10 * log10(max(total - background, 1e-12))
            }
        }

        // Very light smoothing: jumps up almost instantly, settles down quickly
        let weight = voiceDBFS > dbfs ? 0.9 : 0.6
        dbfs = dbfs <= -99 ? voiceDBFS : dbfs * (1 - weight) + voiceDBFS * weight
        db = dbfs + offset
        tick &+= 1
    }

    private func updatePitch(_ hz: Double) {
        pitch = hz > 0 ? hz : 0
    }
}

// MARK: - Exercise 1: Ahh  (tulip grows/shrinks with loudness, green target zone)

struct AahExerciseView: View {
    let audio: AudioMonitor
    var holdGoal: Double = 5
    var onComplete: () -> Void = {}

    private let repsGoal = 3
    private let graceSeconds = 0.4        // short dips below the zone still count

    @State private var held = 0.0
    @State private var reps = 0
    @State private var lastTick = Date()
    @State private var lastInZone = Date.distantPast
    @State private var waitingForSilence = false

    private var inZone: Bool { audio.level >= VoiceTargets.loud }

    private var prompt: (String, Color) {
        if reps >= repsGoal { return ("All done! 🌷", Color.green) }
        if waitingForSilence { return ("Great job! Take a breath.", Color.green) }
        if audio.level < VoiceTargets.silence { return ("Say a strong \"Ahh\"", Color.primary) }
        if !inZone { return ("A little louder!", Color.tulipRed) }
        return ("Great level! Keep going!", Color.green)
    }

    var body: some View {
        VStack(spacing: 12) {
            PromptBanner(text: prompt.0, color: prompt.1)
            Text("Keep the flower in the green zone")
                .font(.title3)
                .foregroundStyle(.secondary)

            VoiceTulip(level: audio.level, style: .band, headSize: 90, groundHeight: 36)

            VStack(spacing: 10) {
                Text(String(format: "%.1f of %.0f seconds", min(held, holdGoal), holdGoal))
                    .font(.title3.weight(.semibold).monospacedDigit())
                ProgressView(value: min(held, holdGoal), total: holdGoal)
                    .scaleEffect(x: 1, y: 3, anchor: .center)
                    .padding(.vertical, 4)
                RepDots(done: reps, total: repsGoal)
                Text("Goal: about \(Int(VoiceTargets.targetDB)) dB")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if reps >= repsGoal {
                    Button("Do It Again") { reps = 0; held = 0; waitingForSilence = false }
                        .buttonStyle(BigButtonStyle(kind: .primary))
                }
            }
        }
        .padding(20)
        .onChange(of: audio.tick) { handle() }
    }

    private func handle() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.1)
        lastTick = now
        guard reps < repsGoal else { return }

        if waitingForSilence {
            if audio.level < VoiceTargets.silence {
                waitingForSilence = false
                held = 0
            }
            return
        }

        if inZone { lastInZone = now }
        if now.timeIntervalSince(lastInZone) < graceSeconds {
            held += dt
            if held >= holdGoal {
                reps += 1
                waitingForSilence = true
                if reps >= repsGoal { onComplete() }
            }
        }
    }
}

// MARK: - Exercise 2: Pitch Glide  (bud blooms as pitch slides up)

struct PitchExerciseView: View {
    let audio: AudioMonitor
    var onComplete: () -> Void = {}

    private let goalSemitones = 5.0
    private let repsGoal = 5

    @State private var samples: [Double] = []
    @State private var baseHz: Double?
    @State private var progress = 0.0
    @State private var reachedGoal = false
    @State private var reps = 0
    @State private var quietSince: Date?

    private var prompt: (String, Color) {
        if reps >= repsGoal { return ("All done! 🌷", Color.green) }
        if reachedGoal { return ("It bloomed! 🌷", Color.green) }
        if audio.level < VoiceTargets.silence { return ("Start low, slide up high", Color.primary) }
        return ("Higher!", Color.tulipRed)
    }

    var body: some View {
        ZStack {
            SkyBackground()

            VStack(spacing: 12) {
                PromptBanner(text: prompt.0, color: prompt.1)
                Text("Make the tulip bloom")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.black.opacity(0.7))
                RepDots(done: reps, total: repsGoal)
                if reps >= repsGoal {
                    Button("Do It Again") { reps = 0; reachedGoal = false; progress = 0 }
                        .buttonStyle(BigButtonStyle(kind: .primary))
                        .padding(.horizontal, 20)
                }
                Spacer()
                TulipView(growth: 0.6,
                          bloom: reachedGoal ? 1 : progress,
                          maxStem: 170,
                          headSize: 130)
                GrassStrip(showTulips: false)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .onChange(of: audio.tick) { handle() }
    }

    private func handle() {
        guard reps < repsGoal else { return }

        if audio.level < VoiceTargets.silence || audio.pitch <= 0 {
            if quietSince == nil { quietSince = Date() }
            if let q = quietSince, Date().timeIntervalSince(q) > 0.6 {
                baseHz = nil
                samples = []
                reachedGoal = false
                progress = 0
            }
            return
        }
        quietSince = nil

        if baseHz == nil {
            samples.append(audio.pitch)
            if samples.count >= 5 { baseHz = samples.sorted()[samples.count / 2] }
            return
        }
        guard let base = baseHz else { return }

        let semitones = 12 * log2(audio.pitch / base)
        progress = min(max(semitones / goalSemitones, 0), 1)

        if progress >= 1 && !reachedGoal {
            reachedGoal = true
            reps += 1
            if reps >= repsGoal { onComplete() }
        }
    }
}

// MARK: - Exercise 3: Counting  (a tulip pops up for each number at target volume)

struct CountExerciseView: View {
    let audio: AudioMonitor
    var onComplete: () -> Void = {}

    private let total = 10

    @State private var count = 0
    @State private var inWord = false
    @State private var wordCounted = false
    @State private var quietSince: Date? = Date()
    @State private var dipSince: Date?
    @State private var quietWord = false

    private var prompt: (String, Color) {
        if count >= total { return ("You counted to 10! 🌷", Color.green) }
        if quietWord { return ("A little louder!", Color.tulipRed) }
        if count == 0 { return ("Count out loud: 1 to 10", Color.primary) }
        return ("Now say \(count + 1)!", Color.primary)
    }

    var body: some View {
        VStack(spacing: 16) {
            PromptBanner(text: prompt.0, color: prompt.1)
            Text("A flower appears at the target volume")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            VStack(spacing: 8) {
                HStack(spacing: 4) { ForEach(1...5, id: \.self) { slot($0) } }
                HStack(spacing: 4) { ForEach(6...10, id: \.self) { slot($0) } }
            }
            Rectangle().fill(Color.leafGreen.opacity(0.35)).frame(height: 12)

            Spacer()

            LoudnessMeter(level: audio.level, target: VoiceTargets.loud)

            Button("Start Over") {
                withAnimation { count = 0 }
                quietWord = false
                inWord = false
                wordCounted = false
                dipSince = nil
            }
            .buttonStyle(BigButtonStyle(kind: .secondary))
        }
        .padding(20)
        .onChange(of: audio.tick) { handle() }
    }

    private func slot(_ n: Int) -> some View {
        let isNext = n == count + 1
        return VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                if n <= count {
                    TulipView(growth: 0.4, bloom: 1, maxStem: 40, headSize: 46)
                        .transition(.scale(scale: 0.1, anchor: .bottom).combined(with: .opacity))
                } else {
                    Circle()
                        .stroke(isNext ? Color.tulipRed : Color.green.opacity(0.6),
                                style: StrokeStyle(lineWidth: isNext ? 4 : 3, dash: [6, 6]))
                        .frame(width: 54, height: 54)
                        .padding(.bottom, 16)
                }
            }
            .frame(height: 100)

            Text("\(n)")
                .font(.title.bold())
                .foregroundStyle(n <= count ? Color.tulipRed : Color.primary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Number \(n)")
        .accessibilityValue(n <= count ? "Done" : "Not yet")
    }

    private func bloomNext() {
        quietWord = false
        withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { count += 1 }
        if count >= total { onComplete() }
    }

    private func handle() {
        guard count < total else { return }
        let now = Date()
        let l = audio.level

        if l >= VoiceTargets.silence {
            quietSince = nil
            if !inWord {
                inWord = true
                wordCounted = false
                dipSince = nil
            }
            // Count the instant this word reaches the target
            if !wordCounted && l >= VoiceTargets.loud {
                wordCounted = true
                bloomNext()
            }
            // Numbers said without a pause: a clear dip, then loud again = next number
            if wordCounted {
                if l < VoiceTargets.loud - 0.12 {
                    if dipSince == nil { dipSince = now }
                } else if l >= VoiceTargets.loud, let d = dipSince, now.timeIntervalSince(d) > 0.12 {
                    dipSince = nil
                    bloomNext()
                } else if l >= VoiceTargets.loud {
                    dipSince = nil
                }
            }
        } else {
            if quietSince == nil { quietSince = now }
            if inWord, let q = quietSince, now.timeIntervalSince(q) > 0.06 {
                inWord = false
                if !wordCounted { quietWord = true }
            }
        }
    }
}

// MARK: - Exercise 4: Reading  (garden scene, big text, confetti on success)

struct ReadExerciseView: View {
    let audio: AudioMonitor
    var onComplete: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let passThreshold = 0.6   // share of speaking time that must reach the green

    private let passages = [
        "Spring is here. The tulips in the garden are red and yellow. Every morning I water them and watch them grow a little taller.",
        "On Saturday we went to the farmers market. We bought fresh bread, honey, and a big bunch of flowers for the kitchen table.",
        "My grandson called me today. He told me all about his soccer game. His team won, and he scored the very last goal."
    ]

    @State private var index = 0
    @State private var spokenTime = 0.0
    @State private var loudTime = 0.0
    @State private var lastTick = Date()
    @State private var success = false
    @State private var resultMessage: String?
    @State private var showConfetti = false

    private var score: Double { spokenTime > 0 ? loudTime / spokenTime : 0 }

    private var prompt: (String, Color) {
        if success { return ("Amazing reading! 🎉", Color.green) }
        if audio.level < VoiceTargets.silence { return ("Read this out loud", Color.black) }
        if audio.level < VoiceTargets.loud { return ("A little louder!", Color.tulipRed) }
        return ("Great volume!", Color.green)
    }

    var body: some View {
        ZStack {
            SkyBackground()

            VStack(spacing: 14) {
                PromptBanner(text: prompt.0, color: prompt.1)

                ScrollView {
                    Text(passages[index])
                        .font(.system(size: 28, weight: .medium))
                        .lineSpacing(10)
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
                .frame(maxHeight: 300)
                .background(Color.white.opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                .padding(.horizontal, 20)

                if let resultMessage {
                    Text(resultMessage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(Color.orange.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 20)
                }

                Spacer(minLength: 0)

                HStack(alignment: .bottom, spacing: 12) {
                    VoiceTulip(level: audio.level, style: .dashed, headSize: 56, groundHeight: 0)
                        .frame(width: 110, height: 180)

                    VStack(spacing: 10) {
                        if spokenTime > 1 && !success {
                            Text("Loud enough \(Int(score * 100))% of the time")
                                .font(.headline)
                                .foregroundStyle(score >= passThreshold ? Color.green : Color.tulipRed)
                                .multilineTextAlignment(.center)
                        }
                        Button(success ? "Next Story" : "I'm Done Reading",
                               action: success ? nextPassage : finishReading)
                            .buttonStyle(BigButtonStyle(kind: .primary, height: 76))
                    }
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 20)

                GrassStrip(showTulips: true)
            }
            .ignoresSafeArea(edges: .bottom)

            if showConfetti && !reduceMotion {
                ConfettiView()
            }
        }
        .onChange(of: audio.tick) { handle() }
    }

    private func handle() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.1)
        lastTick = now
        guard !success else { return }
        if audio.level >= VoiceTargets.silence {
            spokenTime += dt
            if audio.level >= VoiceTargets.loud { loudTime += dt }
        }
    }

    private func finishReading() {
        guard spokenTime > 3 else {
            resultMessage = "I didn't hear much. Try reading the whole story out loud."
            return
        }
        if score >= passThreshold {
            success = true
            resultMessage = nil
            showConfetti = true
            onComplete()
            Task {
                try? await Task.sleep(for: .seconds(5))
                showConfetti = false
            }
        } else {
            resultMessage = "Almost! \(Int(score * 100))% was loud enough. Try again a little louder."
            spokenTime = 0
            loudTime = 0
        }
    }

    private func nextPassage() {
        index = (index + 1) % passages.count
        success = false
        resultMessage = nil
        spokenTime = 0
        loudTime = 0
    }
}

// MARK: - Voice-driven tulip with target marker

struct VoiceTulip: View {
    enum Style { case band, dashed }

    let level: Double
    var style: Style = .band
    var headSize: CGFloat = 90
    var groundHeight: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxStem = max(h - groundHeight - headSize - 34, 40)
            let yLow  = headY(VoiceTargets.loud, h: h, maxStem: maxStem)
            let yHigh = headY(VoiceTargets.loudHigh, h: h, maxStem: maxStem)
            let inZone = level >= VoiceTargets.loud

            ZStack {
                switch style {
                case .band:
                    Rectangle()
                        .fill(Color.green.opacity(inZone ? 0.9 : 0.3))
                        .frame(width: w, height: max(yLow - yHigh, 18))
                        .position(x: w / 2, y: (yLow + yHigh) / 2)
                    Text("Target")
                        .font(.headline)
                        .foregroundStyle(inZone ? Color.white : Color.green)
                        .position(x: 44, y: (yLow + yHigh) / 2)
                case .dashed:
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: yLow))
                        p.addLine(to: CGPoint(x: w, y: yLow))
                    }
                    .stroke(inZone ? Color.green : Color.tulipRed,
                            style: StrokeStyle(lineWidth: 4, dash: [10, 7]))
                }

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    TulipView(growth: level,
                              bloom: inZone ? 1 : 0.45,
                              maxStem: maxStem,
                              headSize: headSize)
                    if groundHeight > 0 {
                        Rectangle().fill(Color.leafGreen).frame(height: groundHeight)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice flower")
        .accessibilityValue(level >= VoiceTargets.loud ? "In the target zone" : "Below the target")
    }

    private func headY(_ g: Double, h: CGFloat, maxStem: CGFloat) -> CGFloat {
        let clamped = CGFloat(min(max(g, 0), 1))
        return h - groundHeight - (24 + maxStem * clamped) - headSize * 0.3
    }
}

// MARK: - Tulip Drawing

struct TulipView: View {
    var growth: Double              // 0 = short sprout, 1 = full height
    var bloom: Double               // 0 = closed green bud, 1 = open flower
    var maxStem: CGFloat = 220
    var headSize: CGFloat = 70
    var color: Color = .tulipRed

    var body: some View {
        let g = CGFloat(min(max(growth, 0), 1))
        let stem = 24 + maxStem * g

        // No growth animation: the stem follows the voice directly (~100 updates/second)
        VStack(spacing: -headSize * 0.2) {
            TulipHead(bloom: bloom, color: color)
                .frame(width: headSize, height: headSize)
                .zIndex(1)
            Capsule()
                .fill(Color.leafGreen)
                .frame(width: max(headSize * 0.12, 4), height: stem)
                .overlay(alignment: .bottom) {
                    Ellipse()
                        .fill(Color.leafGreen.opacity(0.85))
                        .frame(width: headSize * 0.35, height: min(headSize * 0.9, stem * 0.7 + 10))
                        .rotationEffect(.degrees(35), anchor: .bottom)
                        .offset(x: headSize * 0.12)
                }
        }
        .animation(.easeOut(duration: 0.15), value: bloom)
        .accessibilityHidden(true)
    }
}

struct TulipHead: View {
    var bloom: Double
    var color: Color = .tulipRed

    var body: some View {
        let b = min(max(bloom, 0), 1)
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(color.opacity(0.75))
                    .frame(width: w * 0.45, height: h * 0.85)
                    .rotationEffect(.degrees(-30 * b), anchor: .bottom)
                    .offset(x: -w * 0.12 * b)
                Ellipse()
                    .fill(color.opacity(0.75))
                    .frame(width: w * 0.45, height: h * 0.85)
                    .rotationEffect(.degrees(30 * b), anchor: .bottom)
                    .offset(x: w * 0.12 * b)
                Ellipse()
                    .fill(color)
                    .overlay(Ellipse().fill(Color.leafGreen.opacity((1 - b) * 0.6)))
                    .frame(width: w * (0.45 + 0.1 * b), height: h * 0.95)
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
    }
}

// MARK: - Scenery (the sun is the microphone badge, so it isn't drawn here)

struct SkyBackground: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                LinearGradient(colors: [.skyTop, .skyBottom], startPoint: .top, endPoint: .bottom)
                Image(systemName: "cloud.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
                    .position(x: w * 0.42, y: h * 0.06)
                Image(systemName: "cloud.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.white.opacity(0.9))
                    .position(x: w * 0.68, y: h * 0.2)
                Image(systemName: "cloud.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.85))
                    .position(x: w * 0.15, y: h * 0.26)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct GrassStrip: View {
    var showTulips = true

    private let heights: [Double] = [0.5, 0.8, 0.6, 0.9, 0.55, 0.75, 0.65]
    private let colors: [Color] = [.tulipRed, .tulipYellow, .tulipPink, .tulipRed, .tulipYellow, .tulipPink, .tulipRed]

    var body: some View {
        VStack(spacing: 0) {
            if showTulips {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<heights.count, id: \.self) { i in
                        TulipView(growth: heights[i], bloom: 1, maxStem: 40, headSize: 34, color: colors[i])
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            Rectangle()
                .fill(Color.leafGreen)
                .frame(height: 50)
        }
        .accessibilityHidden(true)
    }
}

struct ConfettiView: View {
    struct Piece {
        let x: Double, delay: Double, speed: Double, size: Double
        let color: Color, spin: Double, drift: Double
    }

    @State private var start = Date()
    @State private var pieces: [Piece] = ConfettiView.makePieces()

    static func makePieces() -> [Piece] {
        let palette: [Color] = [.tulipRed, .tulipYellow, .tulipPink, .orange, .green, .purple]
        return (0..<140).map { _ in
            Piece(x: .random(in: 0...1),
                  delay: .random(in: 0...1.0),
                  speed: .random(in: 0.22...0.42),
                  size: .random(in: 7...13),
                  color: palette.randomElement() ?? .tulipRed,
                  spin: .random(in: 1...4),
                  drift: .random(in: -40...40))
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSince(start)
                for p in pieces {
                    let tt = t - p.delay
                    guard tt > 0 else { continue }
                    let y = -20 + tt * p.speed * size.height
                    guard y < size.height + 20 else { continue }
                    let x = p.x * size.width + sin(tt * p.spin) * p.drift
                    var c = ctx
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(tt * p.spin * 2))
                    let rect = CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)
                    c.fill(Path(rect), with: .color(p.color))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Shared Exercise Components

struct PromptBanner: View {
    let text: String
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(.system(size: 40, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.6)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.horizontal, 16)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct LoudnessMeter: View {
    let level: Double
    let target: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray5))
                    Capsule()
                        .fill(level >= target ? Color.green : Color.tulipRed.opacity(0.7))
                        .frame(width: max(14, w * level))
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 4)
                        .offset(x: w * target - 2)
                }
            }
            .frame(height: 30)

            HStack {
                Text("Quiet").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("Target ▲").font(.callout.bold())
                Spacer()
                Text("Loud").font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loudness")
        .accessibilityValue(level >= target ? "On target" : "Too quiet")
    }
}

struct RepDots: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                ForEach(0..<total, id: \.self) { i in
                    Circle()
                        .fill(i < done ? Color.tulipRed : Color(.systemGray4))
                        .frame(width: 22, height: 22)
                }
            }
            Text("\(min(done, total)) of \(total) done")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(min(done, total)) of \(total) done")
    }
}

// MARK: - Shared Styles

struct LargeFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.title3)
            .padding(.horizontal, 16)
            .frame(minHeight: 64)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(Color(.systemGray3), lineWidth: 2))
    }
}

/// Orange boxed error so it doesn't blend in with the red buttons.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(Color.orange, lineWidth: 2))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}

#Preview {
    ContentView()
        .environment(TherapyPlan())
        .tint(.tulipRed)
        .preferredColorScheme(.light)
}