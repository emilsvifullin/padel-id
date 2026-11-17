import SwiftUI

struct GroupPaymentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Plan: String, CaseIterable {
        case month = "Месяц"
        case season = "Сезон"
    }

    let referenceDate: Date?
    let renewal: RenewalProgress?
    let initialFrequency: TrainingFrequency
    let pricing: (TrainingFrequency, Date) -> SubscriptionPricing
    let onRequestFrequency: ((TrainingFrequency) -> Void)?
    let onViewSchedule: ((TrainingQuote) -> Void)?
    let onViewCurrentSchedule: (() -> Void)?
    let onPay: ((TrainingCheckout) -> Void)?
    let onPaymentQuestion: ((TrainingQuote?) -> Void)?

    @ScaledMetric(relativeTo: .largeTitle) private var priceSize = 48.0
    @ScaledMetric(relativeTo: .largeTitle) private var quoteHeight = 196.0
    @State private var plan: Plan
    @State private var frequencyChoice: Int
    @State private var preferredSessions: Int
    @State private var includesNextMonth = false
    @State private var showsSBPUnavailable = false
    @State private var frequencyRequestStart: TrainingFrequency?
    @State private var schedulePreview: SchedulePreview?

    private struct SchedulePreview: Identifiable {
        let dates: [Date]
        var id: [Date] { dates }
    }

    private var isRenewal: Bool { renewal != nil }
    private var hasCustomFrequency: Bool { frequencyChoice == TrainingFrequency.customRange.lowerBound }
    private var frequency: TrainingFrequency {
        if isRenewal { return renewal?.approvedFrequency ?? initialFrequency }
        return TrainingFrequency(rawValue: hasCustomFrequency ? preferredSessions : frequencyChoice) ?? initialFrequency
    }

    init(
        frequency: TrainingFrequency,
        referenceDate: Date? = nil,
        renewal: RenewalProgress? = nil,
        initialPlan: Plan = .month,
        pricing: @escaping (TrainingFrequency, Date) -> SubscriptionPricing,
        onRequestFrequency: ((TrainingFrequency) -> Void)? = nil,
        onViewSchedule: ((TrainingQuote) -> Void)? = nil,
        onViewCurrentSchedule: (() -> Void)? = nil,
        onPay: ((TrainingCheckout) -> Void)? = nil,
        onPaymentQuestion: ((TrainingQuote?) -> Void)? = nil
    ) {
        self.referenceDate = referenceDate
        self.renewal = renewal
        initialFrequency = frequency
        self.pricing = pricing
        self.onRequestFrequency = onRequestFrequency
        self.onViewSchedule = onViewSchedule
        self.onViewCurrentSchedule = onViewCurrentSchedule
        self.onPay = onPay
        self.onPaymentQuestion = onPaymentQuestion
        _plan = State(initialValue: initialPlan)
        let firstCustomFrequency = TrainingFrequency.customRange.lowerBound
        _frequencyChoice = State(initialValue: min(frequency.rawValue, firstCustomFrequency))
        _preferredSessions = State(initialValue: max(frequency.rawValue, firstCustomFrequency))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            paymentContent(on: referenceDate ?? context.date)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .sheet(item: $frequencyRequestStart) { firstOption in
            RenewalFrequencySheet(firstOption: firstOption, format: frequencyLabel) { requested in
                onRequestFrequency?(requested)
                frequencyRequestStart = nil
            }
        }
        .alert("Оплата по СБП пока недоступна", isPresented: $showsSBPUnavailable) {
            Button("Понятно", role: .cancel) {}
        }
        .sheet(item: $schedulePreview) { preview in
            NavigationStack {
                List(preview.dates, id: \.self) { date in
                    Text(Self.trainingDate(date))
                }
                .navigationTitle("Новый график")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Закрыть", systemImage: "xmark") { schedulePreview = nil }
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func paymentContent(on date: Date) -> some View {
        let subscription = pricing(frequency, date)
        let twoMonthQuote = !isRenewal && plan == .month ? subscription.twoMonthQuote : nil
        let selectedQuote: TrainingQuote? = switch (renewal, plan) {
        case let (renewal?, _): renewal.offer(using: subscription)
        case (nil, .season): subscription.seasonQuote
        case (nil, .month): (includesNextMonth ? twoMonthQuote : nil) ?? subscription.monthQuote
        }
        let checkout = selectedQuote.map { renewal?.checkout(for: $0) ?? TrainingCheckout(quote: $0) }
        let showsPlanOptions = !isRenewal

        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    Text(paymentTitle)
                        .font(.display(.title, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)

                    if showsPlanOptions {
                        VStack(spacing: 12) {
                            Picker("Период оплаты", selection: $plan) {
                                ForEach(Plan.allCases, id: \.self) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)

                            if let twoMonthQuote, let upcoming = twoMonthQuote.months.last {
                                nextMonthToggle(upcoming, savings: twoMonthQuote.savings)
                                    .transition(replacementTransition)
                            }
                        }

                        frequencyPicker
                    }

                    ZStack(alignment: .top) {
                        if let checkout {
                            quoteContent(checkout, season: subscription.currentSeason, at: date)
                                .transition(replacementTransition)
                        } else {
                            unavailableOffer(subscription, at: date)
                                .transition(replacementTransition)
                        }
                    }
                    .frame(minHeight: quoteHeight, alignment: .top)
                    .geometryGroup()

                    if let onPaymentQuestion {
                        Button {
                            onPaymentQuestion(selectedQuote)
                        } label: {
                            Label("Вопрос по оплате", systemImage: "message")
                                .font(.subheadline.weight(.medium))
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, showsPlanOptions ? 64 : 28)
                .padding(.bottom, 28)
                .frame(maxWidth: 390)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(showsPlanOptions ? .top : .center, for: .alignment)

            VStack(spacing: 6) {
                if let onViewCurrentSchedule, checkout?.amount != 0 {
                    Button("Текущее расписание", action: onViewCurrentSchedule)
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                }
                if checkout != nil || !isRenewal {
                    paymentActions(for: checkout)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .padelAnimation(Motion.standard, value: plan)
        .padelAnimation(Motion.standard, value: frequency)
        .padelAnimation(Motion.standard, value: includesNextMonth)
        .padelAnimation(Motion.standard, value: selectedQuote?.kind)
        .padelAnimation(Motion.standard, value: renewal?.request)
    }

    private var renewalOptions: some View {
        VStack(spacing: 4) {
            Text(frequencyLabel(frequency))
                .font(.subheadline)
                .contentTransition(.numericText(value: Double(frequency.rawValue)))

            if case let .pending(requested) = renewal?.request {
                Text("На рассмотрении · \(frequencyLabel(requested))")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                if renewal?.request == .unavailable {
                    Text("Свободных мест для дополнительных занятий нет")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.72))
                }

                if onRequestFrequency != nil, let next = TrainingFrequency(rawValue: frequency.rawValue + 1) {
                    Button("Изменить частоту") {
                        frequencyRequestStart = next
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var replacementTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.16).delay(0.12)),
            removal: .opacity.animation(.easeOut(duration: 0.10))
        )
    }

    private var paymentTitle: String {
        isRenewal ? "Продление абонемента" : "Абонемент"
    }

    private var frequencyPicker: some View {
        VStack(spacing: 8) {
            Text("Занятий в неделю")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
                .accessibilityHidden(true)

            Picker("Занятий в неделю", selection: $frequencyChoice) {
                Text("1 раз").tag(1)
                Text("2 раза").tag(2)
                Text("Больше").tag(TrainingFrequency.customRange.lowerBound)
            }
            .pickerStyle(.segmented)

            if hasCustomFrequency {
                customFrequency
                    .transition(.opacity.combined(with: .offset(y: -5)))
            }
        }
    }

    private func nextMonthToggle(_ upcoming: TrainingQuote.Month, savings: Int) -> some View {
        Toggle(isOn: $includesNextMonth) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Включить следующий месяц")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if savings > 0 {
                    Text("Экономия \(Self.rubles(savings))")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(savings)))
                        .transition(.opacity)
                } else {
                    Text("\(Self.monthTitle(upcoming.start)) · \(sessionsLabel(upcoming.count))")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(upcoming.count)))
                        .transition(.opacity)
                }
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.78))
            .multilineTextAlignment(.leading)
        }
        .tint(Color(uiColor: .systemGreen))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func quoteContent(_ checkout: TrainingCheckout, season: TrainingSeason, at date: Date) -> some View {
        let quote = checkout.quote
        let showsBalance = checkout.alreadyPaid > 0 && checkout.amount > 0
        let displayedPrice = checkout.amount > 0 ? checkout.amount : quote.price

        return VStack(spacing: 9) {
            VStack(spacing: 4) {
                if checkout.amount > 0 {
                    Text(showsBalance ? "К доплате" : "К оплате")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.72))
                        .contentTransition(.opacity)
                }

                Text(Self.rubles(displayedPrice))
                    .font(.system(size: priceSize, weight: .semibold))
                    .tracking(-1.6)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText(value: Double(displayedPrice)))
                    .padelAnimation(Motion.standard, value: displayedPrice)
            }
            .accessibilityElement(children: .combine)

            Text(quoteTitle(quote, season: season))
                .font(.headline)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(quote.count)))
                .padelAnimation(Motion.standard, value: quote.count)

            if quote.seasonSavings > 0 {
                seasonDiscount(quote)
                    .transition(.opacity)
            }

            quoteBreakdown(quote)

            Text(checkout.amount == 0 ? "Абонемент оплачен" : quoteExplanation(quote, hasBalance: showsBalance, at: date))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
                .contentTransition(.opacity)

            if showsBalance {
                Text("Оплачено \(Self.rubles(checkout.alreadyPaid)) · всего \(Self.rubles(quote.price))")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
            }

            if isRenewal {
                renewalOptions.padding(.top, 6)
                if renewal?.approvedFrequency != nil, checkout.amount > 0 {
                    Button("Посмотреть новый график") {
                        schedulePreview = SchedulePreview(dates: quote.sessions.filter { $0 > date })
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func quoteBreakdown(_ quote: TrainingQuote) -> some View {
        let showsMonths = quote.kind == .twoMonths

        if let month = quote.months.first,
           showsMonths || quote.months.allSatisfy({ $0.sessionPrice == month.sessionPrice }) {
            VStack(spacing: 9) {
                let count = showsMonths ? month.count : quote.count
                let calculation = "\(count) × \(Self.rubles(month.sessionPrice))"
                let label = showsMonths ? "\(Self.monthTitle(month.start)) · \(calculation)" : calculation
                Text(label)
                    .contentTransition(.numericText(value: Double(count * month.sessionPrice)))

                if showsMonths, let upcoming = quote.months.last {
                    Text("\(Self.monthTitle(upcoming.start)) · \(upcoming.count) × \(Self.rubles(upcoming.sessionPrice))")
                        .contentTransition(.numericText(value: Double(upcoming.subtotal)))
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .font(.subheadline.monospacedDigit())
            .transition(.opacity)
        }
    }

    private func quoteTitle(_ quote: TrainingQuote, season: TrainingSeason) -> String {
        switch quote.kind {
        case .season: "\(season.label) · \(sessionsLabel(quote.count))"
        case .twoMonths: sessionsLabel(quote.count)
        case .singleVisit: "Разовое занятие"
        default: "\(Self.monthTitle(quote.periodStart)) · \(sessionsLabel(quote.count))"
        }
    }

    private func quoteExplanation(_ quote: TrainingQuote, hasBalance: Bool, at date: Date) -> String {
        if let renewal {
            if date >= quote.periodStart, !renewal.isOverdue(at: date), !hasBalance {
                return "Сегодня последний день оплаты. В сумму входят оставшиеся занятия."
            }
            if date >= quote.periodStart {
                return hasBalance ? "Доплата за дополнительные занятия, которые ещё не начались."
                    : "К оплате только оставшиеся занятия. Место пока за вами."
            }
            return hasBalance ? "Доплатите не позднее \(Self.dayMonth(renewal.periodStart))."
                : "Оплатите не позднее \(Self.dayMonth(renewal.periodStart)). Место пока за вами."
        }
        return switch quote.kind {
        case .twoMonths: "В этом месяце оплачиваются оставшиеся занятия."
        case .singleVisit:
            "До конца месяца осталось одно занятие."
        case .remainingMonth: "В расчёт входят занятия с момента оплаты."
        case .nextMonth: "Включены все занятия следующего месяца."
        case .season: "Каждый месяц рассчитан по своему тарифу. Скидка действует на занятия до конца сезона."
        }
    }

    private func sessionsLabel(_ count: Int) -> String {
        let ending: String
        switch (count % 100, count % 10) {
        case (11...14, _): ending = "занятий"
        case (_, 1): ending = "занятие"
        case (_, 2...4): ending = "занятия"
        default: ending = "занятий"
        }
        return "\(count) \(ending)"
    }

    private func frequencyLabel(_ frequency: TrainingFrequency) -> String {
        "\(sessionsLabel(frequency.rawValue)) в неделю"
    }

    private func unavailableOffer(_ pricing: SubscriptionPricing, at date: Date) -> some View {
        let seasonClosed = plan == .season && !pricing.isSeasonOnSale
        let title: String
        let detail: String?
        if let renewal {
            if renewal.seat == .released {
                title = "Место в группе освобождено"
                detail = "Чтобы продолжить занятия, свяжитесь с администратором."
            } else if renewal.isOverdue(at: date), !renewal.latePaymentAllowed, renewal.paidQuote == nil {
                title = "Срок оплаты прошёл"
                detail = "Чтобы оплатить оставшиеся занятия, свяжитесь с администратором."
            } else if !renewal.scheduleReady {
                title = "Расписание готовится"
                detail = "Оплата откроется, когда администратор подтвердит даты."
            } else {
                title = "В этом месяце не осталось занятий"
                detail = nil
            }
        } else if seasonClosed {
            title = "Продажа на сезон закрыта"
            detail = "Следующий сезон можно оплатить с \(Self.dayMonth(pricing.nextSeasonStart))."
        } else {
            title = "Пока нет занятий для оплаты"
            detail = nil
        }

        return VStack(spacing: 8) {
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
    }

    private func seasonDiscount(_ quote: TrainingQuote) -> some View {
        let oldPrice = Self.rubles(quote.subtotal)
        let percent = TrainingSeason.discountPercent
        let discount = Self.rubles(quote.seasonSavings)
        let isExactPercentage = quote.seasonSavings * 100 == quote.subtotal * percent

        return HStack(spacing: 10) {
            Text(oldPrice)
                .strikethrough()
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(quote.subtotal)))
                .foregroundStyle(.white.opacity(0.66))
                .accessibilityLabel("Цена без скидки \(oldPrice)")

            Text(isExactPercentage ? "−\(percent)%" : "−\(discount)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(quote.seasonSavings)))
                .foregroundStyle(.black)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(.white, in: .capsule)
                .accessibilityLabel("Скидка \(discount)")
        }
        .font(.subheadline)
    }

    private var customFrequency: some View {
        Stepper(value: $preferredSessions, in: TrainingFrequency.customRange) {
            Text(frequencyLabel(frequency))
                .font(.headline)
                .contentTransition(.numericText(value: Double(preferredSessions)))
                .padelAnimation(Motion.standard, value: preferredSessions)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity)
    }

    private func paymentActions(for checkout: TrainingCheckout?) -> some View {
        let paid = checkout?.amount == 0
        let label = paid ? "К расписанию" : (checkout?.alreadyPaid ?? 0) > 0 ? "Доплатить по СБП" : "Оплатить по СБП"

        return Button(label) {
            guard let checkout else { return }
            if paid {
                onViewSchedule?(checkout.quote)
            } else if let onPay {
                onPay(checkout)
            } else {
                showsSBPUnavailable = true
            }
        }
        .buttonStyle(AuthenticationButtonStyle(pressScale: 0.985))
        .disabled(checkout == nil || (paid && onViewSchedule == nil))
    }

    static func rubles(_ amount: Int) -> String {
        amount.formatted(.currency(code: "RUB").precision(.fractionLength(0)).locale(Locale(identifier: "ru_RU")))
    }

    private static let dateFormat = Date.FormatStyle(
        locale: Locale(identifier: "ru_RU"),
        calendar: SubscriptionPricing.calendar,
        timeZone: SubscriptionPricing.calendar.timeZone
    )

    private static func monthTitle(_ date: Date) -> String {
        date.formatted(dateFormat.month(.wide)).capitalized
    }

    private static func dayMonth(_ date: Date) -> String {
        date.formatted(dateFormat.day().month(.wide))
    }

    static func trainingDate(_ date: Date) -> String {
        date.formatted(dateFormat.day().month(.wide).hour().minute())
    }
}

private struct RenewalFrequencySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: Int
    let firstOption: TrainingFrequency
    let format: (TrainingFrequency) -> String
    let onRequest: (TrainingFrequency) -> Void

    init(firstOption: TrainingFrequency, format: @escaping (TrainingFrequency) -> String,
         onRequest: @escaping (TrainingFrequency) -> Void) {
        self.firstOption = firstOption
        self.format = format
        self.onRequest = onRequest
        _sessions = State(initialValue: firstOption.rawValue)
    }

    private var frequency: TrainingFrequency { TrainingFrequency(rawValue: sessions) ?? firstOption }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Администратор проверит свободные места и подтвердит новый график.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Stepper(value: $sessions, in: firstOption.rawValue...TrainingFrequency.eightTimes.rawValue) {
                    Text(format(frequency))
                        .font(.headline)
                        .contentTransition(.numericText(value: Double(sessions)))
                        .padelAnimation(Motion.standard, value: sessions)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                Button("Отправить запрос") { onRequest(frequency) }
                    .buttonStyle(AuthenticationButtonStyle(pressScale: 0.985))
            }
            .padding(24)
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle("Дополнительные занятия")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .tint(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(270), .medium, .large])
    }
}
