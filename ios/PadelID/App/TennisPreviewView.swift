#if (DEBUG && targetEnvironment(simulator)) || TENNIS_PREVIEW
import SwiftUI
import UIKit

struct TennisPreviewView: View {
    enum Scenario {
        case account(slowSignIn: Bool = false)
        case matchPoint
        case subscription(TrainingFrequency, example: PaymentExample = .today)
        case renewal(PaymentExample = .earlyRenewal)
        case playerHome(PlayerExample = .schedule)
    }

    enum PlayerExample {
        case schedule, clubReplacement, makeup, subscription, carryover
    }

    private static let arguments = ProcessInfo.processInfo.arguments
    private static let showsMenu: Bool = {
        #if TENNIS_PREVIEW
        true
        #else
        arguments.contains("-previewTennis")
        #endif
    }()

    static var launchScenario: Scenario? {
        if arguments.contains("-previewPlayerHome") { return .playerHome() }
        if arguments.contains("-previewOnboarding") { return .matchPoint }
        if arguments.contains("-previewGroupPaymentOnceWeekly") { return .subscription(.onceWeekly) }
        if arguments.contains("-previewTwoMonthPayment") { return .subscription(.twiceWeekly, example: .midNovember) }
        if arguments.contains("-previewOverdueRenewal") { return .renewal(.overdueRenewal) }
        if arguments.contains("-previewRenewal") { return .renewal() }
        if arguments.contains("-previewGroupPayment") { return .subscription(.twiceWeekly) }
        if showsMenu { return .account() }
        return nil
    }

    @State var scenario: Scenario
    @State private var auth = TennisAuth(preview: true)
    @State private var playerAccount = LocalPlayerAccount()
    @State private var history: TrainingHistory?
    @State private var assessment: AssessmentRole?
    @State private var runID = UUID()
    @State private var showsCheckout = false
    @State private var cancellations: [Date: TrainingCancellation] = [:]
    @State private var renewal = RenewalProgress(periodStart: PaymentExample.renewalPeriodStart)

    var body: some View {
        content
            .id(runID)
            .environment(auth)
            .overlayPreferenceValue(PlayerChrome.self) { mode in
                if Self.showsMenu && (mode == .standard || mode == .player) {
                    let usesPlayerHeader = mode == .player
                    PreviewMenuBar(menu: testMenu, leading: false)
                        .frame(width: 72, height: usesPlayerHeader ? PlayerHeaderLayout.height : 48)
                        .padding(.horizontal, usesPlayerHeader ? PlayerHeaderLayout.sideInset : 8)
                        .padding(.top, usesPlayerHeader ? PlayerHeaderLayout.topInset : 8)
                        .frame(maxWidth: usesPlayerHeader ? PlayerHeaderLayout.contentWidth : .infinity,
                               alignment: .topTrailing)
                        .opacity(showsCheckout ? 0.52 : 1)
                        .allowsHitTesting(!showsCheckout)
                        .accessibilityHidden(showsCheckout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .alert("Tennis ID", isPresented: Binding(
                get: { auth.notice != nil },
                set: { if !$0 { auth.notice = nil } }
            )) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(auth.notice ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch scenario {
        case .account:
            TennisEntryView { _ in
                MatchPointView(history: $history, assessment: $assessment, onOpenSchedule: {
                    start(.playerHome())
                }) {
                    Task { await auth.signOut() }
                }
            }
        case .matchPoint:
            MatchPointView(history: $history, assessment: $assessment) {
                start(.account())
            }
        case let .subscription(frequency, example):
            PreviewSubscriptionView(frequency: frequency, example: example, showsCheckout: $showsCheckout,
                                    cancellations: $cancellations, account: playerAccount, onSignOut: leavePlayerArea,
                                    settingsLeadingControl: settingsMenu)
        case let .renewal(example):
            PreviewSubscriptionView(frequency: .onceWeekly, example: example, renewal: $renewal,
                                    showsCheckout: $showsCheckout, cancellations: $cancellations,
                                    account: playerAccount, onSignOut: leavePlayerArea, settingsLeadingControl: settingsMenu)
        case let .playerHome(example):
            let paid = PaymentExample.playerQuote(renewed: example == .carryover)
            let schedule = PaymentExample.playerSchedule(paid)
            let initialTraining = example == .clubReplacement ? schedule.first { training in
                if case .clubReplacement = training.clubCancellation { return true }
                return false
            } : nil
            PlayerAreaView(sessions: schedule, passes: [paid].compactMap { $0 },
                           paidMonths: PaymentExample.paidMonths(in: schedule, frequency: .twiceWeekly),
                           makeupSlots: PaymentExample.makeupSlots, referenceDate: PaymentExample.playerDate,
                           initialTraining: initialTraining, cancellations: $cancellations,
                           account: playerAccount, onSignOut: leavePlayerArea,
                           selection: example == .subscription ? .subscription : .schedule,
                           settingsLeadingControl: settingsMenu)
            .background { Color.black.ignoresSafeArea() }
        }
    }

    private var settingsMenu: AnyView? {
        guard Self.showsMenu else { return nil }
        return AnyView(PreviewMenuBar(menu: testMenu, leading: true)
            .frame(width: 72, height: PlayerHeaderLayout.height))
    }

    private var testMenu: UIMenu {
        var sections: [UIMenuElement] = [
            UIMenu(title: "Сценарии", options: .displayInline, children: [
                menuAction("Вход и регистрация") { start(.account()) },
                menuAction("Вход с ожиданием") { start(.account(slowSignIn: true)) },
                menuAction("Анкета MatchPoint") { start(.matchPoint) },
                menuAction("Первый абонемент") { start(.subscription(.onceWeekly)) },
                menuAction("Продление абонемента") { start(.renewal()) },
                menuAction("Кабинет игрока") { start(.playerHome()) },
                menuAction("Замена после отмены клубом") { start(.playerHome(.clubReplacement)) },
                UIMenu(title: "Отработки и абонемент", children: [
                    menuAction("Отработка после отмены") { start(.playerHome(.makeup)) },
                    menuAction("Отработка после продления") { start(.playerHome(.carryover)) },
                    menuAction("Абонемент игрока") { start(.playerHome(.subscription)) }
                ]),
                UIMenu(title: "Примеры расчёта", children: [
                    menuAction("15 ноября · два месяца") {
                        start(.subscription(.twiceWeekly, example: .midNovember))
                    },
                    menuAction("15 сентября · сезон") {
                        start(.subscription(.onceWeekly, example: .september))
                    },
                    menuAction("Одна тренировка до конца месяца") {
                        start(.subscription(.onceWeekly, example: .lastLesson))
                    },
                    menuAction("1 декабря · последний день оплаты") { start(.renewal(.renewalDeadline)) },
                    menuAction("Расписание ещё готовится") {
                        start(.renewal())
                        renewal.scheduleReady = false
                    },
                    menuAction("Просроченное продление") { start(.renewal(.overdueRenewal)) }
                ])
            ])
        ]

        if case .renewal = scenario, case .pending = renewal.request {
            sections.append(UIMenu(title: "Решение по запросу", options: .displayInline, children: [
                menuAction("Подтвердить дополнительные занятия") { renewal.resolveRequest(hasAvailability: true) },
                menuAction("Нет свободных мест") { renewal.resolveRequest(hasAvailability: false) }
            ]))
        }

        if case .renewal = scenario, !renewal.scheduleReady {
            sections.append(menuAction("Подтвердить даты продления") { renewal.scheduleReady = true })
        }

        if case .renewal(.overdueRenewal) = scenario, renewal.paidQuote == nil, renewal.seat != .released {
            var seatActions: [UIAction] = []
            if renewal.seat == .held, let date = PaymentExample.overdueRenewal.referenceDate {
                seatActions.append(menuAction("Связались с игроком") { renewal.recordContact(at: date) })
            } else {
                if !renewal.latePaymentAllowed {
                    seatActions.append(menuAction("Разрешить позднюю оплату") { renewal.allowLatePayment() })
                }
                seatActions.append(menuAction("Освободить место", attributes: .destructive) {
                    renewal.releaseSeat()
                })
            }
            sections.append(UIMenu(title: "Место в группе", options: .displayInline, children: seatActions))
        }

        if case .account = scenario {
            var actions = [menuAction("Открыть ссылку сброса пароля") { auth.openPreviewRecovery() }]
            if auth.isPreviewRegistrationPending {
                actions.insert(menuAction("Подтвердить почту") { auth.confirmPreviewRegistration() }, at: 0)
            }
            sections.append(UIMenu(title: "Тестовый вход · Tennis123", options: .displayInline, children: actions))
        }

        sections.append(menuAction("Начать сценарий заново", symbol: "arrow.counterclockwise") { start(scenario) })
        return UIMenu(children: sections)
    }

    private func menuAction(_ title: String, symbol: String? = nil, attributes: UIMenuElement.Attributes = [],
                            perform: @escaping () -> Void) -> UIAction {
        UIAction(title: title, image: symbol.flatMap { UIImage(systemName: $0) }, attributes: attributes) { _ in
            perform()
        }
    }

    private func start(_ scenario: Scenario) {
        if case .account(slowSignIn: true) = scenario {
            auth = TennisAuth(preview: true, previewSignInDelay: .seconds(1.5))
        } else {
            auth = TennisAuth(preview: true)
        }
        history = nil
        assessment = nil
        showsCheckout = false
        cancellations = [:]
        if case let .playerHome(example) = scenario,
           example == .makeup || example == .carryover || example == .subscription {
            cancellations[PaymentExample.makeupSource] = .withMakeup
        }
        renewal = RenewalProgress(periodStart: PaymentExample.renewalPeriodStart)
        self.scenario = scenario
        runID = UUID()
    }

    private func leavePlayerArea() {
        playerAccount.clearDraft()
        start(.account())
    }
}

private struct PreviewMenuBar: UIViewRepresentable {
    let menu: UIMenu
    let leading: Bool

    func makeUIView(context: Context) -> UINavigationBar {
        let bar = UINavigationBar()
        bar.items = [UINavigationItem()]
        return bar
    }

    func updateUIView(_ bar: UINavigationBar, context: Context) {
        guard let item = bar.topItem else { return }
        let more = item.leftBarButtonItem ?? item.rightBarButtonItem ??
            UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
        more.accessibilityLabel = "Меню проверки"
        more.tintColor = .white
        more.menu = menu
        if leading {
            item.rightBarButtonItem = nil
            item.leftBarButtonItem = more
        } else {
            item.leftBarButtonItem = nil
            item.rightBarButtonItem = more
        }
    }
}

enum PaymentExample {
    case today, september, midNovember, lastLesson, earlyRenewal, renewalDeadline, overdueRenewal

    private static let calendar = SubscriptionPricing.calendar
    private static let lessonTimes = [(2, 18), (5, 18), (3, 18), (4, 18), (2, 19), (5, 19), (3, 19), (4, 19)]
    private static let court = TrainingCourt(name: "VITASPORT", address: "Москва, Живописная ул., 21, корп. 2",
                                             shortAddress: "Живописная ул., 21, корп. 2",
                                             photoAsset: "VitasportCourt")

    static var renewalPeriodStart: Date { date(month: 12, day: 1, hour: 0) }
    static var playerDate: Date { date(month: 11, day: 16) }

    static var makeupSource: Date { date(month: 11, day: 19, hour: 18) }
    static var makeupSlots: [Date] {
        [date(month: 11, day: 20, hour: 19), date(month: 11, day: 28, hour: 18), date(month: 12, day: 4, hour: 19)]
    }

    static func playerQuote(renewed: Bool) -> TrainingQuote? {
        let example = PaymentExample.midNovember
        let pricing = example.pricing(for: .twiceWeekly, at: date(month: 11, day: 15))
        return renewed ? pricing.twoMonthQuote : pricing.monthQuote
    }

    static func playerSchedule(_ quote: TrainingQuote?) -> [ScheduledTraining] {
        return schedule(quote).map { training in
            var training = training
            switch training.startsAt {
            case date(month: 11, day: 23, hour: 18):
                training.clubCancellation = .clubReplacement([
                    date(month: 11, day: 27, hour: 18),
                    date(month: 12, day: 2, hour: 19)
                ])
            case date(month: 11, day: 26, hour: 18):
                training.clubCancellation = .clubAwaitingReplacement
            default: break
            }
            return training
        }
    }

    static func schedule(_ quote: TrainingQuote?) -> [ScheduledTraining] {
        schedule(on: quote?.sessions ?? [])
    }

    static func schedule(on dates: [Date]) -> [ScheduledTraining] {
        dates.map { ScheduledTraining(startsAt: $0, court: court) }
    }

    static func paidMonths(in sessions: [ScheduledTraining], frequency: TrainingFrequency) -> [Date: TrainingFrequency] {
        let months = Set(sessions.map { calendar.dateInterval(of: .month, for: $0.startsAt)!.start })
        return Dictionary(uniqueKeysWithValues: months.map { ($0, frequency) })
    }

    static func makeupSlots(near now: Date) -> [Date] {
        (1...60).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: now),
                  [4, 7].contains(calendar.component(.weekday, from: date)) else { return nil }
            return calendar.date(bySettingHour: 19, minute: 0, second: 0, of: date)
        }
    }

    static var currentRenewalSchedule: [ScheduledTraining] {
        schedule(currentRenewalQuote)
    }

    static var currentRenewalQuote: TrainingQuote? {
        let start = date(month: 11, day: 1, hour: 0)
        return PaymentExample.earlyRenewal.pricing(for: .onceWeekly, at: start).monthQuote
    }

    var referenceDate: Date? {
        switch self {
        case .today: nil
        case .september: Self.date(month: 9, day: 15)
        case .midNovember: Self.date(month: 11, day: 15)
        case .lastLesson: Self.date(month: 11, day: 29)
        case .earlyRenewal: Self.date(month: 11, day: 16)
        case .renewalDeadline: Self.date(month: 12, day: 1)
        case .overdueRenewal: Self.date(month: 12, day: 15)
        }
    }

    func pricing(for frequency: TrainingFrequency, at date: Date) -> SubscriptionPricing {
        let start = Self.calendar.dateInterval(of: .month, for: date)!.start
        let end = Self.calendar.date(byAdding: .month, value: 5, to: start)!
        var scheduled: [Date] = []
        var day = start

        while day < end {
            let weekday = Self.calendar.component(.weekday, from: day)
            for (lessonDay, hour) in Self.lessonTimes.prefix(frequency.rawValue) where lessonDay == weekday {
                scheduled.append(Self.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!)
            }
            day = Self.calendar.date(byAdding: .day, value: 1, to: day)!
        }

        return SubscriptionPricing(now: date, frequency: frequency, scheduled: scheduled)
    }

    private static func date(month: Int, day: Int, hour: Int = 12) -> Date {
        // Fixed local samples keep checkout scenarios reproducible.
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
}

private struct PreviewSubscriptionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let frequency: TrainingFrequency
    let example: PaymentExample
    var renewal: Binding<RenewalProgress>? = nil
    @Binding var showsCheckout: Bool
    @Binding var cancellations: [Date: TrainingCancellation]
    let account: LocalPlayerAccount
    let onSignOut: () -> Void
    let settingsLeadingControl: AnyView?

    @State private var showsDecline = false
    @State private var showsUpdatedQuote = false
    @State private var payment: TrainingCheckout?
    @State private var isConfirmed = false
    @State private var didFinishConfirmation = false
    @State private var showsSchedule = false
    @State private var showsSupport = false

    var body: some View {
        ZStack {
            if !didFinishConfirmation {
                paymentScreen
                .opacity(isConfirmed ? 0 : 1)
                .allowsHitTesting(!isConfirmed)
                .accessibilityElement(children: .contain)
                .accessibilityHidden(isConfirmed)
                .transition(.identity)
            }

            confirmation
                .opacity(isConfirmed ? 1 : 0)
                .allowsHitTesting(isConfirmed)
                .accessibilityElement(children: .contain)
                .accessibilityHidden(!isConfirmed)
        }
        .background {
            ZStack {
                Color.black.ignoresSafeArea()
                MatchPointBackground().opacity(showsSchedule ? 0 : 1)
            }
        }
        .overlayPreferenceValue(PlayerChrome.self) { mode in
            if showsSchedule && renewal != nil && mode != .focused {
                Button("К продлению", systemImage: "chevron.backward", action: returnToRenewal)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .tint(.white)
                    .frame(height: PlayerHeaderLayout.height)
                    .padding(.trailing, 96)
                    .padding(.top, PlayerHeaderLayout.topInset)
                    .frame(maxWidth: PlayerHeaderLayout.contentWidth, alignment: .topTrailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .allowsHitTesting(!showsCheckout)
        .accessibilityHidden(showsCheckout)
        .overlay {
            if showsCheckout {
                checkoutDialog
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .alert("Оплата отклонена", isPresented: $showsDecline) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text("Попробуйте оплатить ещё раз.")
        }
        .alert("Расчёт обновился", isPresented: $showsUpdatedQuote) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text("Проверьте сумму и даты перед оплатой.")
        }
        .sensoryFeedback(.success, trigger: isConfirmed && !showsSchedule) { _, confirmed in confirmed }
        .fullScreenCover(isPresented: $showsSupport) {
            NavigationStack {
                PlayerSupportView(account: account)
                    .navigationTitle("Поддержка")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Назад", systemImage: "chevron.backward") { showsSupport = false }
                                .labelStyle(.iconOnly)
                                .tint(.white)
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var paymentScreen: some View {
        let openCurrentSchedule: (() -> Void)? = currentPaidSessions.isEmpty ? nil : { showSchedule() }
        return GroupPaymentView(
            frequency: frequency, referenceDate: example.referenceDate,
            renewal: renewal?.wrappedValue, initialPlan: example == .september ? .season : .month,
            pricing: example.pricing,
            onRequestFrequency: requestFrequency, onViewSchedule: { _ in showSchedule() },
            onViewCurrentSchedule: openCurrentSchedule,
            onPay: { checkout in
                payment = checkout
                withAnimation(reduceMotion ? nil : Motion.quick) { showsCheckout = true }
            },
            onPaymentQuestion: { quote in
                account.draftTopic = quote.map(SupportTopic.payment) ??
                    SupportTopic(kind: .payment, detail: renewal == nil ? "Первый абонемент" : "Продление")
                showsSupport = true
            }
        )
    }

    private var checkoutDialog: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Проверка оплаты")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Сумма заказа — \(GroupPaymentView.rubles(payment?.amount ?? 0)).")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                checkoutButton("Подтвердить оплату", action: confirmPayment)
                checkoutButton("Отклонить") {
                    dismissCheckout()
                    showsDecline = true
                }
                checkoutButton("Отменить", action: dismissCheckout)
            }
            .padding(16)
            .frame(maxWidth: 320)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))
            .padding(.horizontal, 24)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, dismissCheckout)
        }
        .environment(\.colorScheme, .dark)
    }

    private func checkoutButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(.white.opacity(0.12), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func dismissCheckout() {
        withAnimation(reduceMotion ? nil : Motion.quick) {
            showsCheckout = false
            payment = nil
        }
    }

    private func confirmPayment() {
        guard showsCheckout, !isConfirmed, let payment else { return }
        let now = example.referenceDate ?? .now
        let recorded: Bool
        if let renewal {
            let selectedFrequency = renewal.wrappedValue.approvedFrequency ?? frequency
            let pricing = example.pricing(for: selectedFrequency, at: now)
            recorded = renewal.wrappedValue.recordPayment(payment, using: pricing)
        } else {
            let pricing = example.pricing(for: payment.quote.frequency, at: now)
            recorded = pricing.isCurrentFirstCheckout(payment)
        }
        guard recorded else {
            dismissCheckout()
            showsUpdatedQuote = true
            return
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42)) {
            isConfirmed = true
            showsCheckout = false
        } completion: {
            didFinishConfirmation = true
        }
    }

    private func requestFrequency(_ requested: TrainingFrequency) {
        renewal?.wrappedValue.requestIncrease(to: requested, from: frequency)
    }

    private func showSchedule() {
        withAnimation(reduceMotion ? nil : Motion.standard) {
            showsSchedule = true
            isConfirmed = true
        } completion: {
            didFinishConfirmation = true
        }
    }

    private var currentPaidSessions: [ScheduledTraining] {
        guard renewal != nil else { return [] }
        let now = example.referenceDate ?? .now
        return PaymentExample.currentRenewalSchedule.filter { $0.startsAt > now }
    }

    private var visibleSchedule: [ScheduledTraining] {
        if let renewal { return PaymentExample.currentRenewalSchedule + PaymentExample.schedule(renewal.wrappedValue.paidQuote) }
        return PaymentExample.schedule(payment?.quote)
    }

    private var paidScheduleMonths: [Date: TrainingFrequency] {
        if let renewal {
            var months = PaymentExample.paidMonths(in: PaymentExample.currentRenewalSchedule, frequency: frequency)
            if let paid = renewal.wrappedValue.paidQuote {
                months[paid.periodStart] = paid.frequency
            }
            return months
        }
        return PaymentExample.paidMonths(in: visibleSchedule, frequency: payment?.quote.frequency ?? frequency)
    }

    private var paidPasses: [TrainingQuote] {
        if let renewal {
            return [PaymentExample.currentRenewalQuote, renewal.wrappedValue.paidQuote].compactMap { $0 }
        }
        return [payment?.quote].compactMap { $0 }
    }

    private func returnToRenewal() {
        withAnimation(reduceMotion ? nil : Motion.standard) {
            didFinishConfirmation = false
            isConfirmed = false
            showsSchedule = false
        }
    }

    private var confirmation: some View {
        ZStack {
            if showsSchedule {
                PlayerAreaView(sessions: visibleSchedule, passes: paidPasses, paidMonths: paidScheduleMonths,
                               makeupSlots: PaymentExample.makeupSlots(near: example.referenceDate ?? .now),
                               referenceDate: example.referenceDate, initialTraining: nil,
                               cancellations: $cancellations, account: account, onSignOut: onSignOut,
                               settingsLeadingControl: settingsLeadingControl)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    paymentConfirmation

                    Button("К расписанию") {
                        withAnimation(reduceMotion ? nil : Motion.standard) { showsSchedule = true }
                    }
                    .buttonStyle(AuthenticationButtonStyle())
                    .disabled(!isConfirmed)
                    .accessibilityHidden(!isConfirmed)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var paymentConfirmation: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                paymentCheckmark.padding(.bottom, 8)
                Text("Оплата подтверждена")
                    .font(.display(.title, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                if let payment {
                    Text(GroupPaymentView.rubles(payment.amount))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var paymentCheckmark: some View {
        let progress: CGFloat = isConfirmed ? 1 : 0
        let stroke = StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)

        return ZStack {
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.white.opacity(0.54), style: stroke)
                .rotationEffect(.degrees(-90))

            Path { path in
                path.move(to: CGPoint(x: 20, y: 34))
                path.addLine(to: CGPoint(x: 28, y: 43))
                path.addLine(to: CGPoint(x: 46, y: 20))
            }
            .trim(from: 0, to: progress)
            .stroke(.white, style: stroke)
        }
        .frame(width: 64, height: 64)
        .frame(width: 76, height: 76)
        .accessibilityHidden(true)
    }
}
#endif
