import Foundation

@main
struct PricingCheck {
    static func main() {
        let calendar = SubscriptionPricing.calendar
        func date(_ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }

        func check(_ title: String, _ result: Bool) {
            guard result else {
                print("FAIL \(title)")
                exit(1)
            }
            print("PASS \(title)")
        }

        check("One/week, no discount", TrainingFrequency.onceWeekly.monthlySessionPrice(for: 8) == 3750)
        check("Two/week, 5 and 6 lesson threshold",
              TrainingFrequency.twiceWeekly.monthlySessionPrice(for: 5) == 3750 &&
              TrainingFrequency.twiceWeekly.monthlySessionPrice(for: 6) == 3500)
        check("Three/week, 11 and 12 lesson threshold",
              TrainingFrequency.threeTimes.monthlySessionPrice(for: 11) == 3500 &&
              TrainingFrequency.threeTimes.monthlySessionPrice(for: 12) == 3415)

        let december = [1, 3, 8, 10, 15, 17, 22, 24].map { date(12, $0, 18) }
        let schedule = [date(11, 26, 18), date(11, 26, 18)] + december
        let before = SubscriptionPricing(now: date(11, 14, 23), frequency: .twiceWeekly, scheduled: schedule)
        let boundary = SubscriptionPricing(now: date(11, 15), frequency: .twiceWeekly, scheduled: schedule)
        check("One remaining lesson and no duplicate billing", boundary.monthQuote?.kind == .singleVisit && boundary.monthQuote?.price == 3750)
        check("Two-month opening at Moscow midnight", before.twoMonthQuote == nil && boundary.twoMonthQuote?.price == 31500)

        let september = [date(9, 30, 18), date(10, 2, 18), date(11, 2, 18), date(12, 2, 18)]
        let season = SubscriptionPricing(now: date(9, 1), frequency: .onceWeekly, scheduled: september)
        check("Season offer and ten percent discount", season.seasonQuote?.price == 13500)
        check("Season offer closes after opening month", SubscriptionPricing(now: date(10, 1), frequency: .onceWeekly, scheduled: september).seasonQuote == nil)

        let periodStart = date(12, 1)
        var renewal = RenewalProgress(periodStart: periodStart)
        let pricing = SubscriptionPricing(now: date(11, 30), frequency: .onceWeekly,
                                           scheduled: [date(12, 3, 18), date(12, 10, 18), date(12, 17, 18), date(12, 24, 18)])
        renewal.scheduleReady = false
        check("Unconfirmed dates block initial payment", renewal.offer(using: pricing) == nil)
        renewal.scheduleReady = true
        let initial = renewal.checkout(for: renewal.offer(using: pricing)!)
        check("Initial renewal can be paid only once",
              renewal.recordPayment(initial, using: pricing) && !renewal.recordPayment(initial, using: pricing))
        renewal.requestIncrease(to: .twiceWeekly, from: .onceWeekly)
        renewal.resolveRequest(hasAvailability: true)
        let enlarged = SubscriptionPricing(now: pricing.now, frequency: .twiceWeekly, scheduled: december)
        let supplement = renewal.checkout(for: renewal.offer(using: enlarged)!)
        check("Approved additional lessons charge only difference", supplement.amount == 13000 && renewal.recordPayment(supplement, using: enlarged))

        var overdue = RenewalProgress(periodStart: periodStart)
        let latePricing = SubscriptionPricing(now: date(12, 2), frequency: .twiceWeekly, scheduled: december)
        check("December 1 is payable, December 2 overdue", !overdue.isOverdue(at: date(12, 1, 23)) && overdue.isOverdue(at: latePricing.now))
        overdue.releaseSeat()
        check("Seat held until contact, late checkout blocked", overdue.seat == .held && overdue.offer(using: latePricing) == nil)
        overdue.recordContact(at: latePricing.now)
        overdue.allowLatePayment()
        check("Manual late payment after contact", overdue.offer(using: latePricing) != nil)
        overdue.releaseSeat()
        check("Released seat blocks payment", overdue.offer(using: latePricing) == nil)
    }
}
