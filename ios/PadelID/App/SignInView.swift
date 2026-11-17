import SwiftUI

struct TennisEntryView<PlayerContent: View>: View {
    @Environment(TennisAuth.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasFinishedLaunching = false

    @ViewBuilder let playerContent: (UUID) -> PlayerContent

    private var playerID: UUID? {
        auth.isRestoring || auth.needsNewPassword ? nil : auth.userID
    }

    var body: some View {
        ZStack {
            if let playerID {
                playerContent(playerID)
                    .id(playerID)
                    .transition(.opacity)
                    .zIndex(1)
            } else {
                SignInView()
                    .transition(.opacity)
            }
        }
        .animation(
            hasFinishedLaunching && !auth.needsNewPassword && !reduceMotion ? Motion.standard : nil,
            value: playerID
        )
        .onChange(of: auth.isRestoring, initial: true) { _, isRestoring in
            if !isRestoring { hasFinishedLaunching = true }
        }
    }
}

struct SignInView: View {
    @Environment(TennisAuth.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: AuthenticationForm.Mode = .signIn
    @State private var hasOpenedForm = false
    @State private var showsForm = false

    private var screenAnimation: Animation {
        reduceMotion ? .linear(duration: 0.12) : .easeInOut(duration: 0.26)
    }

    var body: some View {
        ZStack {
            welcome
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .animation(screenAnimation) { view in
                    view.opacity(showsForm ? 0 : 1)
                }
                .opacity(auth.isRestoring ? 0 : 1)
                .allowsHitTesting(!showsForm && !auth.isRestoring)
                .accessibilityHidden(showsForm || auth.isRestoring)

            if hasOpenedForm || auth.needsNewPassword {
                AuthenticationForm(mode: $mode, isPresented: showsForm) { showsForm = false }
                    .animation(screenAnimation) { view in
                        view.opacity(showsForm ? 1 : 0)
                    }
                    .allowsHitTesting(showsForm && !auth.isBusy)
                    .accessibilityHidden(!showsForm)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    Color.black
                    welcomePhoto(in: geometry.size)

                    if hasOpenedForm || auth.needsNewPassword {
                        courtPhoto(in: geometry.size)
                            .animation(screenAnimation) { view in
                                view.opacity(showsForm ? 1 : 0)
                            }
                            .transition(.opacity)
                    }
                }
                .clipped()
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: auth.needsNewPassword, initial: true) { _, needsNewPassword in
            if needsNewPassword {
                showForm(.signIn)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Text("Tennis ID")
                .font(.display(.largeTitle, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 94)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            VStack(spacing: 3) {
                Button {
                    showForm(.signIn)
                } label: {
                    Text("Вход")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuthenticationButtonStyle())

                AccountLinkRow(prompt: "Нет аккаунта?", action: "Создайте его") { label in
                    Button {
                        showForm(.registration)
                    } label: {
                        label
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomePhoto(in size: CGSize) -> some View {
        Image("TennisWelcome")
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.69),
                        .init(color: .black.opacity(0.58), location: 0.83),
                        .init(color: .black.opacity(0.92), location: 0.94),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }

    private func courtPhoto(in size: CGSize) -> some View {
        Image("TennisCourt")
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: min(size.width * 1.19, size.height * 0.62))
            .clipped()
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.72), location: 0),
                        .init(color: .black.opacity(0.20), location: 0.30),
                        .init(color: .black.opacity(0.06), location: 0.51),
                        .init(color: .black.opacity(0.82), location: 0.80),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(.black)
    }

    private func showForm(_ entryMode: AuthenticationForm.Mode) {
        guard !showsForm else { return }
        mode = entryMode

        if hasOpenedForm {
            showsForm = true
        } else {
            withAnimation(screenAnimation) {
                hasOpenedForm = true
                showsForm = true
            }
        }
    }
}

struct AuthenticationButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pressScale: CGFloat = 1

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(.white, in: .capsule)
            .contentShape(.capsule)
            .opacity(opacity(isPressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressScale : 1)
            .padelAnimation(.easeOut(duration: configuration.isPressed ? 0.10 : 0.16), value: configuration.isPressed)
            .padelAnimation(Motion.standard, value: isEnabled)
    }

    private func opacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0.65 }
        return isPressed ? 0.82 : 1
    }
}

private struct AccountLinkRow<Control: View>: View {
    let prompt: String
    let action: String
    @ViewBuilder let control: (AccountActionLabel) -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(prompt)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.trailing)

            control(AccountActionLabel(title: action))
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
    }
}

private struct AccountActionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(minHeight: 44)
            .contentShape(.rect)
    }
}

private struct AuthenticationForm: View {
    enum Mode {
        case signIn, registration

        var title: String { self == .signIn ? "Вход" : "Регистрация" }
        var action: String { self == .signIn ? "Войти" : "Создать аккаунт" }
        var alternatePrompt: String { self == .signIn ? "Нет аккаунта?" : "Уже есть аккаунт?" }
        var alternateAction: String { self == .signIn ? "Создайте его" : "Войдите" }
        var alternate: Self { self == .signIn ? .registration : .signIn }
    }

    private enum Field: Hashable {
        case firstName, lastName, email, password, visiblePassword
    }

    @Environment(TennisAuth.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Binding var mode: Mode
    let isPresented: Bool
    let onBack: () -> Void

    @FocusState private var focus: Field?
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showsPassword = false
    @State private var showsRecovery = false
    @State private var validationError: String?

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var playerName: PlayerName? { PlayerName(first: firstName, last: lastName) }

    private var canSubmit: Bool {
        if auth.needsNewPassword {
            return password.count >= TennisAuth.minimumPasswordLength && auth.isSignedIn
        }
        return !trimmedEmail.isEmpty && !password.isEmpty && (mode != .registration || playerName != nil)
    }

    private var canRequestRecovery: Bool {
        let parts = trimmedEmail.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2
            && !parts[0].isEmpty
            && !parts[1].isEmpty
            && !trimmedEmail.contains(where: \.isWhitespace)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 8)

            ScrollView {
                Group {
                    if auth.needsNewPassword {
                        newPasswordForm
                    } else {
                        accountForm
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 218)
                .padding(.bottom, 32)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.top, for: .sizeChanges)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .disabled(auth.isBusy)
        .sensoryFeedback(.selection, trigger: mode) { _, _ in isPresented }
        .accessibilityAction(.escape, close)
        .onChange(of: email) { clearAccountError() }
        .onChange(of: password) { clearAccountError() }
        .onChange(of: firstName) { clearAccountError() }
        .onChange(of: lastName) { clearAccountError() }
        .onChange(of: isPresented) { _, isPresented in
            if isPresented {
                firstName = ""
                lastName = ""
                email = ""
                password = ""
                showsPassword = false
                showsRecovery = false
            }
        }
        .onChange(of: auth.needsNewPassword) {
            focus = nil
            password = ""
            showsPassword = false
            showsRecovery = false
        }
    }

    private var accountForm: some View {
        VStack(spacing: 22) {
            formTitle(showsRecovery ? "Сброс пароля" : mode.title)

            VStack(alignment: .leading, spacing: 8) {
                credentials

                if let error = validationError ?? auth.accountError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18)
                        .accessibilityLabel("Ошибка. \(error)")
                }
            }

            VStack(spacing: 0) {
                if mode == .signIn {
                    CollapsibleAuthenticationSection(isVisible: !showsRecovery) {
                        Button {
                            setRecoveryVisible(true)
                        } label: {
                            Text("Забыли пароль?")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.82))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .offset(y: -8)
                        .padding(.bottom, 9)
                    }
                }

                submitButton(
                    showsRecovery ? "Отправить ссылку" : mode.action,
                    enabled: showsRecovery ? canRequestRecovery : canSubmit,
                    isSignIn: mode == .signIn && !showsRecovery
                ) {
                    if showsRecovery {
                        requestRecovery()
                    } else {
                        submitAccount()
                    }
                }

                CollapsibleAuthenticationSection(isVisible: !showsRecovery) {
                    ZStack {
                        accountSwitchLink(for: .signIn)
                        accountSwitchLink(for: .registration)
                    }
                    .padding(.top, 3)
                }
            }
        }
    }

    private func accountSwitchLink(for visibleMode: Mode) -> some View {
        AccountLinkRow(prompt: visibleMode.alternatePrompt, action: visibleMode.alternateAction) { label in
            Button(action: switchMode) { label }
                .buttonStyle(.plain)
        }
        .animation(.easeOut(duration: 0.16)) { view in
            view.opacity(mode == visibleMode ? 1 : 0)
        }
        .allowsHitTesting(mode == visibleMode)
        .accessibilityHidden(mode != visibleMode)
    }

    private var newPasswordForm: some View {
        VStack(spacing: 22) {
            formTitle("Новый пароль")

            fieldSurface {
                passwordRow
            }

            submitButton("Сохранить пароль", enabled: canSubmit, action: submitAccount)
        }
    }

    private func submitButton(
        _ title: String,
        enabled: Bool,
        isSignIn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .opacity(auth.isBusy ? 0 : 1)
                .overlay {
                    if auth.isBusy {
                        ProgressView().tint(.black)
                    }
                }
                .animation(isSignIn && !reduceMotion ? .easeInOut(duration: 0.14) : nil, value: auth.isBusy)
        }
        .buttonStyle(AuthenticationButtonStyle(pressScale: isSignIn ? 0.98 : 1))
        .disabled(!enabled || auth.isBusy)
        .accessibilityValue(isSignIn && auth.isBusy ? "Вход выполняется" : "")
    }

    private func formTitle(_ title: String) -> some View {
        Text(title)
            .font(.display(.largeTitle, weight: .semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var header: some View {
        Button(action: close) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Назад")
        .frame(maxWidth: 432, alignment: .leading)
        .overlay(alignment: .center) {
            Text("Tennis ID")
                .font(.display(.subheadline, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
    }

    private var credentials: some View {
        fieldSurface {
            VStack(spacing: 0) {
                CollapsibleAuthenticationSection(isVisible: mode == .registration) {
                    VStack(spacing: 0) {
                        AuthenticationField(onPaddingTap: { focus = .firstName }) {
                            TextField("Имя", text: $firstName, prompt: Text("Имя").foregroundStyle(.white.opacity(0.58)))
                                .textContentType(.givenName)
                                .textInputAutocapitalization(.words)
                                .focused($focus, equals: .firstName)
                                .submitLabel(.next)
                                .onSubmit { focus = .lastName }
                        }

                        fieldDivider

                        AuthenticationField(onPaddingTap: { focus = .lastName }) {
                            TextField("Фамилия", text: $lastName, prompt: Text("Фамилия").foregroundStyle(.white.opacity(0.58)))
                                .textContentType(.familyName)
                                .textInputAutocapitalization(.words)
                                .focused($focus, equals: .lastName)
                                .submitLabel(.next)
                                .onSubmit { focus = .email }
                        }

                        fieldDivider
                    }
                }

                AuthenticationField(onPaddingTap: { focus = .email }) {
                    emailInput
                        .textContentType(showsRecovery ? .emailAddress : .username)
                        .focused($focus, equals: .email)
                        .submitLabel(showsRecovery ? .go : .next)
                        .onSubmit {
                            if showsRecovery {
                                requestRecovery()
                            } else {
                                focus = showsPassword ? .visiblePassword : .password
                            }
                        }
                }

                CollapsibleAuthenticationSection(isVisible: !showsRecovery) {
                    VStack(spacing: 0) {
                        fieldDivider

                        passwordRow
                    }
                }
            }
        }
    }

    private var fieldDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.10))
            .frame(height: 1)
            .padding(.horizontal, 18)
            .accessibilityHidden(true)
    }

    private var passwordRow: some View {
        AuthenticationField(onPaddingTap: { focus = showsPassword ? .visiblePassword : .password }) {
            HStack(spacing: 8) {
                passwordInput
                Button(action: togglePasswordVisibility) {
                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                        .font(.system(size: 16, weight: .medium))
                        .contentTransition(.opacity)
                        .padelAnimation(Motion.quick, value: showsPassword)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .foregroundStyle(.white.opacity(0.62))
                .buttonStyle(.plain)
                .accessibilityLabel(showsPassword ? "Скрыть пароль" : "Показать пароль")
            }
        }
    }

    private var emailInput: some View {
        TextField("Электронная почта", text: $email, prompt: Text("Электронная почта").foregroundStyle(.white.opacity(0.58)))
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func fieldSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22)

        return content()
            .background(reduceTransparency ? Color(white: 0.10) : .white.opacity(0.065), in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.13), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    private var passwordInput: some View {
        let title = auth.needsNewPassword ? "Новый пароль" : "Пароль"
        let prompt = Text(title).foregroundStyle(.white.opacity(0.58))

        return ZStack {
            if showsPassword {
                TextField(title, text: $password, prompt: prompt)
                    .focused($focus, equals: .visiblePassword)
            } else {
                SecureField(title, text: $password, prompt: prompt)
                    .focused($focus, equals: .password)
            }
        }
        .textContentType(mode == .signIn && !auth.needsNewPassword ? .password : .newPassword)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.go)
        .onSubmit(submitAccount)
    }

    private func togglePasswordVisibility() {
        let passwordWasFocused = focus == .password || focus == .visiblePassword
        showsPassword.toggle()
        if passwordWasFocused {
            focus = showsPassword ? .visiblePassword : .password
        }
    }

    private func switchMode() {
        clearAccountError()
        focus = nil
        password = ""
        showsPassword = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            mode = mode.alternate
        }
    }

    private func close() {
        guard !auth.isBusy else { return }
        focus = nil
        clearAccountError()
        if auth.needsNewPassword {
            Task { await auth.signOut() }
        } else if showsRecovery {
            setRecoveryVisible(false)
        } else {
            onBack()
        }
    }

    private func setRecoveryVisible(_ visible: Bool) {
        focus = nil
        clearAccountError()
        if visible {
            password = ""
            showsPassword = false
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            showsRecovery = visible
        }
    }

    private func requestRecovery() {
        guard canRequestRecovery else { return }
        focus = nil
        let address = trimmedEmail
        Task { await auth.requestRecovery(email: address) }
    }

    private func submitAccount() {
        guard canSubmit else { return }
        focus = nil
        clearAccountError()
        let address = trimmedEmail
        let enteredPassword = password
        let registration = mode == .registration
        if auth.needsNewPassword {
            Task { await auth.updatePassword(enteredPassword) }
        } else {
            guard canRequestRecovery else {
                validationError = "Проверьте адрес электронной почты."
                return
            }
            guard !registration || enteredPassword.count >= TennisAuth.minimumPasswordLength else {
                validationError = "Пароль должен содержать не менее \(TennisAuth.minimumPasswordLength) символов."
                return
            }
            let registrationName = registration ? playerName : nil
            Task { await auth.submit(email: address, password: enteredPassword, registrationName: registrationName) }
        }
    }

    private func clearAccountError() {
        validationError = nil
        auth.clearAccountError()
    }
}

private struct CollapsibleAuthenticationSection<Content: View>: View {
    let isVisible: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        CollapsibleAuthenticationLayout(visibleFraction: isVisible ? 1 : 0) {
            content()
        }
        .clipped()
        .contentShape(.rect)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(true, isEnabled: !isVisible)
    }
}

private nonisolated struct CollapsibleAuthenticationLayout: Layout {
    var visibleFraction: CGFloat

    var animatableData: CGFloat {
        get { visibleFraction }
        set { visibleFraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * min(1, max(0, visibleFraction)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(
            at: CGPoint(x: bounds.midX, y: bounds.minY),
            anchor: .top,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}

private struct AuthenticationField<Content: View>: View {
    let onPaddingTap: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.body)
            .frame(minHeight: 44)
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .background {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture(perform: onPaddingTap)
                    .accessibilityHidden(true)
            }
    }
}
