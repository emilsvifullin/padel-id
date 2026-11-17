import SwiftUI
import UIKit

struct PlayerSchedule {
    let sessions: [ScheduledTraining]
    let paidMonths: [Date: TrainingFrequency]
    let makeupSlots: [Date]
    let cancellations: [Date: TrainingCancellation]

    private static let calendar = SubscriptionPricing.calendar

    func status(of training: ScheduledTraining) -> TrainingCancellation? {
        cancellations[training.id] ?? training.clubCancellation
    }

    var sessionsWithBookings: [ScheduledTraining] {
        var result = sessions
        var occupied = Set(sessions.map(\.id))
        var index = 0
        while index < result.count {
            let original = result[index]
            index += 1
            let date: Date
            let isMakeup: Bool
            switch status(of: original) {
            case let .clubReplacementAccepted(booked): (date, isMakeup) = (booked, false)
            case let .makeupBooked(booked): (date, isMakeup) = (booked, true)
            default: continue
            }
            if occupied.insert(date).inserted {
                result.append(ScheduledTraining(startsAt: date, court: original.court, replaces: original.id, isMakeup: isMakeup))
            }
        }
        return result
    }

    var pendingMakeups: [ScheduledTraining] {
        sessionsWithBookings.filter { status(of: $0)?.hasOpenMakeup == true }.sorted { $0.id < $1.id }
    }

    func makeupDeadline(for original: Date) -> Date {
        let source = Self.calendar.dateInterval(of: .month, for: original)!
        guard let frequency = paidMonths[source.start], paidMonths[source.end] != nil else { return source.end }
        let next = Self.calendar.dateInterval(of: .month, for: source.end)!
        let used = sessionsWithBookings.filter { training in
            guard training.id >= source.start, training.id < source.end,
                  case let .makeupBooked(booked) = status(of: training) else { return false }
            return booked >= next.start && booked < next.end
        }.count
        let remaining = max(0, min(4, frequency.rawValue) - used)
        let transferable = pendingMakeups.filter { $0.id >= source.start && $0.id < source.end }.prefix(remaining)
        return transferable.contains { $0.id == original } ? next.end : source.end
    }

    func makeupOptions(for training: ScheduledTraining, at now: Date) -> [Date] {
        guard status(of: training) == .withMakeup else { return [] }
        let deadline = makeupDeadline(for: training.id)
        let occupied = Set(sessionsWithBookings.map(\.id))
        return Array(Set(makeupSlots).filter {
            $0 > max(now, training.id) && $0 < deadline && !occupied.contains($0)
        }.sorted().prefix(3))
    }

    func awaitingClubReplacements(in pass: TrainingQuote) -> Int {
        let dates = Set(pass.sessions)
        return sessions.filter { training in
            guard dates.contains(training.id) else { return false }
            return switch status(of: training) {
            case .clubReplacement, .clubReplacementDeclined, .clubAwaitingReplacement: true
            default: false
            }
        }.count
    }

    func remainingSessions(in pass: TrainingQuote, at now: Date) -> Int {
        let dates = Set(pass.sessions)
        let upcoming = sessionsWithBookings.filter {
            $0.startsAt > now && !$0.isMakeup && status(of: $0) == nil && dates.contains($0.replaces ?? $0.id)
        }.count
        return upcoming + awaitingClubReplacements(in: pass)
    }
}

struct PlayerSubscriptionView: View {
    let schedule: PlayerSchedule
    let passes: [TrainingQuote]
    let referenceDate: Date?
    let onSelectMakeup: (ScheduledTraining) -> Void
    let onPaymentQuestion: (TrainingQuote) -> Void

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = referenceDate ?? context.date
            let activePasses = passes.sorted { $0.periodStart < $1.periodStart }.filter { $0.validUntil > now }
            let credits = schedule.pendingMakeups
                .map { (training: $0, expires: schedule.makeupDeadline(for: $0.id)) }
                .filter { $0.expires > now }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PlayerSectionTitle("Абонемент")
                        .padding(.bottom, 6)

                    if activePasses.isEmpty {
                        Text("Пока нет оплаченного абонемента.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(activePasses, id: \.periodStart) { pass in
                        VStack(spacing: 16) {
                            MembershipCard(pass: pass, now: now,
                                           remaining: schedule.remainingSessions(in: pass, at: now),
                                           awaitingReplacement: schedule.awaitingClubReplacements(in: pass))
                            paymentQuestion(for: pass)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Отработки")
                                .font(.display(.title3, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Text(credits.count, format: .number)
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Доступных отработок: \(credits.count)")
                        }
                        if credits.isEmpty {
                            Text("Пока нет доступных отработок.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(credits, id: \.training.id) { credit in
                            let hasDates = !schedule.makeupOptions(for: credit.training, at: now).isEmpty
                            Button {
                                onSelectMakeup(credit.training)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("За \(dayMonth(credit.training.id))")
                                            .font(.body.weight(.medium))
                                        Text(hasDates ? "До \(dayMonth(lastDay(of: credit.expires))) включительно" : "Нет свободных дат")
                                            .font(.subheadline)
                                            .foregroundStyle(.white.opacity(0.78))
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(minHeight: 52)
                            }
                            .buttonStyle(PlayerRowButtonStyle(cornerRadius: 12))
                            .padding(.horizontal, -8)
                            .accessibilityHint("Открывает сведения об отработке")
                        }
                    }
                    .padding(18)
                    .background(.white.opacity(0.075), in: .rect(cornerRadius: 22))
                }
                .padding(.horizontal, PlayerHeaderLayout.sideInset)
                .padding(.top, PlayerHeaderLayout.topInset)
                .padding(.bottom, 28)
                .frame(maxWidth: PlayerHeaderLayout.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .foregroundStyle(.white)
    }

    private func paymentQuestion(for pass: TrainingQuote) -> some View {
        Button {
            onPaymentQuestion(pass)
        } label: {
            HStack(spacing: 12) {
                Label("Вопрос по оплате", systemImage: "message")
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
        }
        .buttonStyle(PlayerRowButtonStyle(cornerRadius: 22))
        .background(.white.opacity(0.075), in: .rect(cornerRadius: 22))
    }

    private func dayMonth(_ date: Date) -> String {
        date.formatted(HomeView.dateFormat.day().month(.wide))
    }

    private func lastDay(of end: Date) -> Date {
        SubscriptionPricing.calendar.date(byAdding: .day, value: -1, to: end)!
    }
}

private struct MembershipCard: View {
    let pass: TrainingQuote
    let now: Date
    let remaining: Int
    let awaitingReplacement: Int

    private var name: String {
        switch pass.kind {
        case .singleVisit: "Разовое занятие"
        case .remainingMonth, .nextMonth: "Месячный абонемент"
        case .twoMonths: "На два месяца"
        case .season: "Сезонный абонемент"
        }
    }

    private var period: String {
        let start = pass.periodStart
        let end = pass.months.last!.start
        let calendar = SubscriptionPricing.calendar
        let month = HomeView.dateFormat.month(.wide)
        let startMonth = start.formatted(month).capitalized
        let startYear = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)
        if start == end { return "\(startMonth) \(startYear)" }
        let first = startYear == endYear ? startMonth : "\(startMonth) \(startYear)"
        return "\(first) — \(end.formatted(month)) \(endYear)"
    }

    private var frequency: String {
        let count = pass.frequency.rawValue
        if count == 1 { return "1 занятие в неделю" }
        return "\(count) \(count < 5 ? "занятия" : "занятий") в неделю"
    }

    var body: some View {
        let expiration = SubscriptionPricing.calendar.date(byAdding: .day, value: -1, to: pass.validUntil)!
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label(now < pass.periodStart ? "Оплачен" : "Активен", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.lime)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.64), in: .capsule)

                Text(name)
                    .font(.display(.title2, weight: .semibold))
                    .frame(maxWidth: 228, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 3) {
                    Text(period).font(.subheadline.weight(.semibold))
                    if pass.kind != .singleVisit {
                        Text(frequency).font(.subheadline).foregroundStyle(.white.opacity(0.81))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { artwork }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Осталось занятий")
                            .font(.body.weight(.semibold))
                        if awaitingReplacement > 0 {
                            Text(awaitingReplacement == 1 ? "Из них 1 ждёт замены" : "Из них \(awaitingReplacement) ждут замены")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.76))
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(remaining, format: .number)
                            .font(.title.weight(.semibold))
                        Text("из \(pass.count)")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                }
                .accessibilityElement(children: .combine)
                Divider()
                paymentDetails(expiration: expiration)
            }
            .padding(20)
            .background(Color(white: 0.095))
        }
        .clipShape(.rect(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.13))
                .allowsHitTesting(false)
        }
    }

    private func paymentDetails(expiration: Date) -> some View {
        let value: String
        let label: String
        if pass.kind == .singleVisit, let visit = pass.sessions.first {
            label = "Тренировка"
            value = GroupPaymentView.trainingDate(visit)
        } else {
            label = "Действует по"
            value = expiration.formatted(HomeView.dateFormat.day().month(.wide))
        }
        let total = GroupPaymentView.rubles(pass.price)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                fact(label, value: value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                fact("Оплачено", value: total)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 12) {
                fact(label, value: value)
                fact("Оплачено", value: total)
            }
        }
    }

    private func fact(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.76))
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
    }

    private var artwork: some View {
        GeometryReader { geometry in
            // Photo by Efe Yağız Soysal, Pexels (15935274).
            Image("MembershipCourt")
                .resizable()
                .scaledToFill()
                .saturation(0)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(y: geometry.size.height * 0.30)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .overlay {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.87), location: 0),
                .init(color: .black.opacity(0.68), location: 0.46),
                .init(color: .black.opacity(0.13), location: 0.75)
            ], startPoint: .leading, endPoint: .trailing)
        }
        .accessibilityHidden(true)
    }
}

enum PlayerHeaderLayout {
    static let sideInset: CGFloat = 20
    static let topInset: CGFloat = 4
    static let height: CGFloat = 44
    static let contentWidth: CGFloat = 480
}

struct PlayerSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.display(.largeTitle, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityAddTraits(.isHeader)
            .padding(.trailing, 96)
            .frame(maxWidth: .infinity, minHeight: PlayerHeaderLayout.height, alignment: .leading)
    }
}

struct PlayerAreaView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Section: Int {
        case schedule, subscription, settings

        var title: String {
            switch self {
            case .schedule: "Расписание"
            case .subscription: "Абонемент"
            case .settings: "Настройки"
            }
        }

        var icon: PlayerTabGlyph {
            switch self {
            case .schedule: .calendar
            case .subscription: .membership
            case .settings: .settings
            }
        }
    }

    let sessions: [ScheduledTraining]
    let passes: [TrainingQuote]
    let paidMonths: [Date: TrainingFrequency]
    let makeupSlots: [Date]
    let referenceDate: Date?
    let account: LocalPlayerAccount
    let onSignOut: () -> Void
    let settingsLeadingControl: AnyView?
    @Binding var cancellations: [Date: TrainingCancellation]
    @State private var selection: Section
    @State private var settingsPage = PlayerSettingsPage.overview
    @State private var showsPaymentSupport = false
    @State private var selectedTraining: ScheduledTraining?
    @State private var animatedTab: Section?
    @State private var activation = 0
    @State private var tabMotion = PlayerTabMotion()

    init(sessions: [ScheduledTraining], passes: [TrainingQuote], paidMonths: [Date: TrainingFrequency], makeupSlots: [Date],
         referenceDate: Date?, initialTraining: ScheduledTraining?, cancellations: Binding<[Date: TrainingCancellation]>,
         account: LocalPlayerAccount, onSignOut: @escaping () -> Void,
         selection: Section = .schedule, settingsLeadingControl: AnyView? = nil) {
        self.sessions = sessions
        self.passes = passes
        self.paidMonths = paidMonths
        self.makeupSlots = makeupSlots
        self.referenceDate = referenceDate
        self.account = account
        self.onSignOut = onSignOut
        self.settingsLeadingControl = settingsLeadingControl
        _cancellations = cancellations
        _selection = State(initialValue: selection)
        _selectedTraining = State(initialValue: initialTraining)
    }

    var body: some View {
        let schedule = PlayerSchedule(sessions: sessions, paidMonths: paidMonths,
                                      makeupSlots: makeupSlots, cancellations: cancellations)
        TabView(selection: $selection) {
            Tab(value: .schedule) {
                HomeView(schedule: schedule, referenceDate: referenceDate) { selectedTraining = $0 }
                    .background { iconFeedback(for: .schedule) }
            } label: {
                tabLabel(for: .schedule)
            }
            Tab(value: .subscription) {
                NavigationStack {
                    PlayerSubscriptionView(schedule: schedule, passes: passes, referenceDate: referenceDate,
                                           onSelectMakeup: { selectedTraining = $0 },
                                           onPaymentQuestion: { pass in
                                               account.draftTopic = .payment(pass)
                                               showsPaymentSupport = true
                                           })
                        .toolbarVisibility(.hidden, for: .navigationBar)
                        .navigationDestination(isPresented: $showsPaymentSupport) {
                            PlayerSupportView(account: account)
                                .navigationTitle("Поддержка")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbarVisibility(.visible, for: .navigationBar)
                                .toolbarVisibility(.hidden, for: .tabBar)
                        }
                    .background { Color.black.ignoresSafeArea() }
                }
                .background { iconFeedback(for: .subscription) }
            } label: {
                tabLabel(for: .subscription)
            }
            Tab(value: .settings) {
                PlayerSettingsView(account: account, page: $settingsPage, onSignOut: onSignOut,
                                   overviewLeadingControl: settingsLeadingControl)
                    .background { iconFeedback(for: .settings) }
            } label: {
                tabLabel(for: .settings)
            }
        }
        .preference(key: PlayerChrome.self, value: chromeMode)
        .tint(.white)
        .preferredColorScheme(.dark)
        .onChange(of: selection) { _, section in
            guard !reduceMotion else { return }
            animatedTab = section
            activation += 1
            tabMotion.prepare(activation: activation)
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { tabMotion.stop() }
        }
        .onDisappear { tabMotion.stop() }
        .sheet(item: $selectedTraining) { training in
            TrainingDetails(training: training, referenceDate: referenceDate, paidMonths: paidMonths,
                            makeupSlots: makeupSlots, sessions: sessions, cancellations: $cancellations,
                            account: account)
            .preferredColorScheme(.dark)
        }
    }

    private var chromeMode: PlayerChrome.Mode {
        if selection == .subscription && showsPaymentSupport { return .focused }
        guard selection == .settings else { return .player }
        return settingsPage == .overview ? .settings : .focused
    }

    private func tabLabel(for section: Section) -> some View {
        Label {
            Text(section.title)
        } icon: {
            Image(uiImage: section.icon.image)
                .renderingMode(.template)
        }
    }

    private func iconFeedback(for section: Section) -> some View {
        SystemTabIconFeedback(index: section.rawValue, glyph: section.icon,
                              activation: animatedTab == section ? activation : nil,
                              motion: tabMotion)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct SystemTabIconFeedback: UIViewControllerRepresentable {
    let index: Int
    let glyph: PlayerTabGlyph
    let activation: Int?
    let motion: PlayerTabMotion

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.animate(index: index, glyph: glyph, activation: activation, motion: motion)
    }

    final class Controller: UIViewController {
        private var lastActivation: Int?

        func animate(index: Int, glyph: PlayerTabGlyph, activation: Int?, motion: PlayerTabMotion) {
            guard let activation, lastActivation != activation else { return }
            lastActivation = activation
            Task { @MainActor [weak self] in
                guard let self, self.lastActivation == activation, motion.activation == activation,
                      let tabs = self.tabBarController, tabs.selectedIndex == index else { return }
                let bar = tabs.tabBar
                let icons = self.iconViews(in: bar).sorted {
                    $0.convert($0.bounds, to: bar).midX < $1.convert($1.bounds, to: bar).midX
                }
                // UIKit owns the tab bar. If it doesn't expose one icon column per tab, keep its default transition.
                var columns: [[UIImageView]] = []
                for icon in icons {
                    let x = icon.convert(icon.bounds, to: bar).midX
                    if let first = columns.last?.first, abs(first.convert(first.bounds, to: bar).midX - x) < 8 {
                        columns[columns.count - 1].append(icon)
                    } else {
                        columns.append([icon])
                    }
                }
                let column = bar.effectiveUserInterfaceLayoutDirection == .rightToLeft ? columns.count - 1 - index : index
                guard columns.count == bar.items?.count, columns.indices.contains(column) else { return }
                motion.play(glyph, over: columns[column], activation: activation)
            }
        }

        private func iconViews(in view: UIView) -> [UIImageView] {
            guard !view.isHidden, view.alpha > 0.01 else { return [] }
            if let icon = view as? UIImageView, let size = icon.image?.size,
               (18...36).contains(size.width), abs(size.width - size.height) <= 4 {
                return [icon]
            }
            return view.subviews.flatMap { iconViews(in: $0) }
        }
    }
}
