import Foundation

private let priceStep = 5

enum TrainingFrequency: Int, CaseIterable, Identifiable {
    case onceWeekly = 1
    case twiceWeekly
    case threeTimes
    case fourTimes
    case fiveTimes
    case sixTimes
    case sevenTimes
    case eightTimes

    static let minimumSessionPrice = 2_500
    static let singleSessionPrice = 3_750
    static let customRange = threeTimes.rawValue...eightTimes.rawValue

    var id: Int { rawValue }

    func monthlySessionPrice(for lessonCount: Int) -> Int {
        guard self != .onceWeekly, lessonCount >= 6 else { return Self.singleSessionPrice }

        // Three weekly lessons qualify at 12 paid lessons, four at 16, and so on.
        let eligibleFrequency = min(rawValue, max(Self.twiceWeekly.rawValue, lessonCount / 4))
        let price = 3_500 * pow(0.975, Double(eligibleFrequency - Self.twiceWeekly.rawValue))
        let billableRate = Int((price / Double(priceStep)).rounded(.up)) * priceStep
        return max(Self.minimumSessionPrice, billableRate)
    }
}

enum TrainingSeason {
    case autumn, winterSpring, summer

    static let discountPercent = 10

    init(month: Int) {
        switch month {
        case 1...5: self = .winterSpring
        case 6...8: self = .summer
        default: self = .autumn
        }
    }

    var label: String {
        switch self {
        case .autumn: "Сентябрь — декабрь"
        case .winterSpring: "Январь — май"
        case .summer: "Июнь — август"
        }
    }

    var openingMonth: Int {
        switch self {
        case .autumn: 9
        case .winterSpring: 1
        case .summer: 6
        }
    }

    var monthCount: Int {
        switch self {
        case .autumn: 4
        case .winterSpring: 5
        case .summer: 3
        }
    }
}

struct TrainingQuote: Equatable {
    enum Kind: Hashable {
        case singleVisit, remainingMonth, nextMonth, twoMonths, season
    }

    struct Month: Equatable {
        let start: Date
        let sessions: [Date]
        let sessionPrice: Int

        var count: Int { sessions.count }
        var subtotal: Int { count * sessionPrice }
    }

    let kind: Kind
    let frequency: TrainingFrequency
    let months: [Month]
    var savings: Int = 0

    var periodStart: Date { months[0].start }
    var validUntil: Date { SubscriptionPricing.calendar.dateInterval(of: .month, for: months[months.count - 1].start)!.end }
    var sessions: [Date] { months.flatMap(\.sessions) }
    var count: Int { months.reduce(0) { $0 + $1.count } }
    var subtotal: Int { months.reduce(0) { $0 + $1.subtotal } }

    var seasonSavings: Int {
        guard kind == .season else { return 0 }
        let discount = subtotal * TrainingSeason.discountPercent / 100
        let minimumPrice = count * TrainingFrequency.minimumSessionPrice
        return max(0, min(discount, subtotal - minimumPrice)) / priceStep * priceStep
    }

    var price: Int { subtotal - seasonSavings }
}

struct TrainingCheckout: Equatable {
    let quote: TrainingQuote
    var alreadyPaid = 0

    var amount: Int { max(0, quote.price - alreadyPaid) }
}

struct RenewalProgress {
    enum Seat: Equatable {
        case held, contacted, released
    }

    enum Request: Equatable {
        case pending(TrainingFrequency)
        case unavailable
    }

    let periodStart: Date
    var scheduleReady = true
    private(set) var seat: Seat = .held
    private(set) var latePaymentAllowed = false
    private(set) var request: Request?
    private(set) var approvedFrequency: TrainingFrequency?
    private(set) var paidQuote: TrainingQuote?

    func isOverdue(at date: Date) -> Bool {
        let deadline = SubscriptionPricing.calendar.date(byAdding: .day, value: 1, to: periodStart)!
        return date >= deadline
    }

    func offer(using pricing: SubscriptionPricing) -> TrainingQuote? {
        guard seat != .released else { return nil }
        guard !isOverdue(at: pricing.now) || latePaymentAllowed || paidQuote != nil else { return nil }
        guard scheduleReady else { return paidQuote }
        return pricing.renewalQuote(for: periodStart, keeping: paidQuote)
    }

    mutating func recordContact(at date: Date) {
        guard isOverdue(at: date), seat == .held, paidQuote == nil else { return }
        seat = .contacted
    }

    mutating func allowLatePayment() {
        guard seat == .contacted, paidQuote == nil else { return }
        latePaymentAllowed = true
    }

    mutating func releaseSeat() {
        guard seat == .contacted, paidQuote == nil else { return }
        seat = .released
        latePaymentAllowed = false
        request = nil
    }

    mutating func requestIncrease(to frequency: TrainingFrequency, from current: TrainingFrequency) {
        let active = approvedFrequency ?? current
        guard seat != .released, frequency.rawValue > active.rawValue else { return }
        if case .pending = request { return }
        request = .pending(frequency)
    }

    mutating func resolveRequest(hasAvailability: Bool) {
        guard case let .pending(frequency) = request else { return }
        if hasAvailability {
            approvedFrequency = frequency
            request = nil
        } else {
            request = .unavailable
        }
    }

    func checkout(for quote: TrainingQuote) -> TrainingCheckout {
        let alreadyPaid = paidQuote?.periodStart == quote.periodStart ? paidQuote?.price ?? 0 : 0
        return TrainingCheckout(quote: quote, alreadyPaid: alreadyPaid)
    }

    mutating func recordPayment(_ checkout: TrainingCheckout, using pricing: SubscriptionPricing) -> Bool {
        guard let current = offer(using: pricing), checkout.amount > 0,
              self.checkout(for: current) == checkout else { return false }
        paidQuote = checkout.quote
        return true
    }
}

struct SubscriptionPricing {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }()

    let now: Date
    let frequency: TrainingFrequency
    /// Billable start times after cancellations, including any confirmed make-up lessons.
    let scheduled: [Date]

    private var month: DateInterval { Self.calendar.dateInterval(of: .month, for: now)! }
    private var nextMonth: DateInterval { Self.calendar.dateInterval(of: .month, for: month.end)! }
    private var currentMonthNumber: Int { Self.calendar.component(.month, from: now) }

    var currentSeason: TrainingSeason { TrainingSeason(month: currentMonthNumber) }
    var isSeasonOnSale: Bool { currentMonthNumber == currentSeason.openingMonth }
    var nextSeasonStart: Date {
        let monthsLeft = currentSeason.openingMonth + currentSeason.monthCount - currentMonthNumber
        return Self.calendar.date(byAdding: .month, value: monthsLeft, to: month.start)!
    }

    var monthQuote: TrainingQuote? {
        if let current = monthlyCharge(in: month) {
            return TrainingQuote(kind: current.count == 1 ? .singleVisit : .remainingMonth,
                                 frequency: frequency, months: [current])
        }
        return renewalQuote
    }

    var renewalQuote: TrainingQuote? {
        renewalQuote(for: nextMonth.start)
    }

    func renewalQuote(for periodStart: Date, keeping paidQuote: TrainingQuote? = nil) -> TrainingQuote? {
        guard let period = Self.calendar.dateInterval(of: .month, for: periodStart), now < period.end else { return nil }
        let paidSessions = Set(paidQuote?.sessions ?? [])
        let addedSessions = Set(scheduled.filter { $0 > now && $0 >= period.start && $0 < period.end })
            .subtracting(paidSessions)
        if addedSessions.isEmpty { return paidQuote }

        let sessions = paidSessions.union(addedSessions).sorted()
        let charge = TrainingQuote.Month(start: period.start, sessions: sessions,
                                         sessionPrice: frequency.monthlySessionPrice(for: sessions.count))
        return TrainingQuote(kind: now < period.start ? .nextMonth : .remainingMonth, frequency: frequency, months: [charge])
    }

    var twoMonthQuote: TrainingQuote? {
        let lastDay = Self.calendar.date(byAdding: .day, value: -1, to: month.end)!
        let opensAt = Self.calendar.date(byAdding: .day, value: -15, to: lastDay)!
        guard now >= opensAt, let current = monthlyCharge(in: month),
              let upcoming = monthlyCharge(in: nextMonth) else { return nil }

        let remaining = TrainingQuote.Month(start: current.start, sessions: current.sessions,
                                            sessionPrice: min(current.sessionPrice, upcoming.sessionPrice))
        let savings = current.subtotal - remaining.subtotal
        return TrainingQuote(kind: .twoMonths, frequency: frequency, months: [remaining, upcoming], savings: savings)
    }

    var seasonQuote: TrainingQuote? {
        guard isSeasonOnSale else { return nil }
        let charges = (0..<currentSeason.monthCount).compactMap { offset in
            let start = Self.calendar.date(byAdding: .month, value: offset, to: month.start)!
            return monthlyCharge(in: Self.calendar.dateInterval(of: .month, for: start)!)
        }
        guard !charges.isEmpty else { return nil }
        return TrainingQuote(kind: .season, frequency: frequency, months: charges)
    }

    func isCurrentFirstCheckout(_ checkout: TrainingCheckout) -> Bool {
        let currentQuote = switch checkout.quote.kind {
        case .singleVisit, .remainingMonth, .nextMonth: monthQuote
        case .twoMonths: twoMonthQuote
        case .season: seasonQuote
        }
        guard let currentQuote else { return false }
        return checkout.amount > 0 && checkout == TrainingCheckout(quote: currentQuote)
    }

    private func monthlyCharge(in interval: DateInterval) -> TrainingQuote.Month? {
        let start = max(now, interval.start)
        let sessions = Set(scheduled).filter { $0 >= start && $0 < interval.end }.sorted()
        guard !sessions.isEmpty else { return nil }
        return TrainingQuote.Month(start: interval.start, sessions: sessions,
                                   sessionPrice: frequency.monthlySessionPrice(for: sessions.count))
    }
}
