import SwiftUI

struct TrainingCourt {
    let name: String
    let address: String
    var shortAddress: String? = nil
    var photoAsset: String? = nil

    var directions: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/directions"
        components.queryItems = [URLQueryItem(name: "destination", value: address)]
        return components.url
    }
}

enum TrainingCancellation: Equatable {
    case withMakeup
    case makeupBooked(Date)
    case makeupDatesDeclined
    case late
    case clubReplacement([Date])
    case clubReplacementAccepted(Date)
    case clubReplacementDeclined
    case clubAwaitingReplacement

    var title: String {
        switch self {
        case .withMakeup, .makeupDatesDeclined: "Доступна отработка"
        case .makeupBooked: "Отработка в расписании"
        case .late: "Занятие списано"
        case .clubReplacement, .clubReplacementAccepted, .clubReplacementDeclined, .clubAwaitingReplacement: "Отменено клубом"
        }
    }

    var hasOpenMakeup: Bool { self == .withMakeup || self == .makeupDatesDeclined }
    var needsAttention: Bool { !hasOpenMakeup }

    var hasBookedNewDate: Bool {
        switch self {
        case .makeupBooked, .clubReplacementAccepted: true
        default: false
        }
    }

    var replacementDates: [Date] {
        if case let .clubReplacement(dates) = self { return dates }
        return []
    }

    static func playerCancellation(for startsAt: Date, at now: Date) -> Self? {
        guard now < startsAt else { return nil }
        return now <= deadline(for: startsAt) ? .withMakeup : .late
    }

    static func deadline(for startsAt: Date) -> Date {
        startsAt.addingTimeInterval(-24 * 60 * 60)
    }
}

struct ScheduledTraining: Identifiable {
    let startsAt: Date
    let court: TrainingCourt
    var clubCancellation: TrainingCancellation? = nil
    var replaces: Date? = nil
    var isMakeup = false
    var id: Date { startsAt }

    var bookingLabel: String? {
        guard let replaces else { return nil }
        let source = replaces.formatted(HomeView.dateFormat.day().month(.wide))
        return isMakeup ? "Отработка за \(source)" : "Замена за \(source)"
    }
}

struct HomeView: View {
    let schedule: PlayerSchedule
    let referenceDate: Date?
    let onSelectTraining: (ScheduledTraining) -> Void

    fileprivate static let calendar = SubscriptionPricing.calendar
    static let dateFormat = Date.FormatStyle(
        locale: Locale(identifier: "ru_RU"), calendar: calendar, timeZone: calendar.timeZone
    )

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = referenceDate ?? context.date
            let monthStart = Self.calendar.dateInterval(of: .month, for: now)!.start
            let visible = schedule.sessionsWithBookings
                .filter { training in
                    status(of: training)?.hasBookedNewDate != true
                }
                .filter { training in
                    if training.startsAt > now { return true }
                    guard let status = status(of: training) else { return false }
                    return training.startsAt >= monthStart
                        || (status.hasOpenMakeup && schedule.makeupDeadline(for: training.id) > now)
                }
                .sorted { $0.startsAt < $1.startsAt }
            let next = visible.first { status(of: $0) == nil }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PlayerSectionTitle("Расписание")

                    if let next {
                        nextSession(next)
                    } else {
                        Text("Пока нет предстоящих тренировок.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.74))
                    }

                    sessionList(visible, excluding: next?.id, now: now)

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

    private func status(of training: ScheduledTraining) -> TrainingCancellation? {
        schedule.status(of: training)
    }

    private func nextSession(_ training: ScheduledTraining) -> some View {
        let date = training.startsAt
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                onSelectTraining(training)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Ближайшая тренировка")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.84))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    Text(date.formatted(Self.dateFormat.day().month(.wide)))
                        .font(.display(.title, weight: .semibold))
                    Text("\(Self.weekday(date)) · \(Self.time(date))")
                        .font(.headline)
                        .monospacedDigit()
                    if let bookingLabel = training.bookingLabel {
                        Text(bookingLabel).font(.subheadline)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { courtPhoto }
            }
            .buttonStyle(PlayerRowButtonStyle())
            .accessibilityHint("Открывает детали тренировки")

            TrainingLocationRow(court: training.court, usesShortAddress: true)
                .padding(.horizontal, 18)
        }
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 28))
        .clipShape(.rect(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(.white.opacity(0.10))
                .allowsHitTesting(false)
        }
    }

    private var courtPhoto: some View {
        GeometryReader { geometry in
            Image("TennisCourt")
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .overlay {
            LinearGradient(
                colors: [.black.opacity(0.84), .black.opacity(0.35)],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .accessibilityHidden(true)
    }

    private func sessionList(_ trainings: [ScheduledTraining], excluding next: Date?, now: Date) -> some View {
        let occupied = Set(trainings.filter { status(of: $0) == nil }.map(\.id))
        let byMonth = Dictionary(grouping: trainings.filter { $0.id != next }) {
            Self.calendar.dateInterval(of: .month, for: $0.startsAt)!.start
        }

        return ForEach(byMonth.keys.sorted(), id: \.self) { month in
            VStack(alignment: .leading, spacing: 10) {
                Text(month.formatted(Self.dateFormat.month(.wide)).capitalized)
                    .font(.display(.title3, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 0) {
                    let trainings = byMonth[month, default: []]
                    ForEach(trainings) { training in
                        if training.id != trainings.first?.id {
                            Divider()
                                .overlay(.white.opacity(0.10))
                                .padding(.horizontal, 16)
                        }
                        sessionRow(training, now: now, occupied: occupied)
                    }
                }
                .background(.white.opacity(0.075), in: .rect(cornerRadius: 22))
                .clipShape(.rect(cornerRadius: 22))
            }
        }
    }

    private func sessionRow(_ training: ScheduledTraining, now: Date, occupied: Set<Date>) -> some View {
        let date = training.startsAt
        let cancellation = status(of: training)
        let options = cancellation == .withMakeup
            ? schedule.makeupOptions(for: training, at: now)
            : (cancellation?.replacementDates ?? []).filter { $0 > now && !occupied.contains($0) }
        let optionCount = options.count
        let statusTitle = cancellation?.hasOpenMakeup == true && schedule.makeupDeadline(for: date) <= now
            ? "Срок отработки истёк" : cancellation?.title
        return Button {
            onSelectTraining(training)
        } label: {
            HStack(spacing: 12) {
                Text(date.formatted(Self.dateFormat.day()))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 26, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.weekday(date))
                        .font(.subheadline)
                    if let statusTitle, let cancellation {
                        Text(statusTitle)
                            .font(.footnote)
                            .foregroundStyle(cancellation.needsAttention
                                ? Theme.warningOnDark : .white.opacity(0.74))
                    } else if let bookingLabel = training.bookingLabel {
                        Text(bookingLabel)
                            .font(.footnote)
                    }
                    if optionCount > 0 {
                        Text(optionCount == 1 ? "Выбрать время · 1 вариант" : "Выбрать время · \(optionCount) варианта")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .foregroundStyle(.white.opacity(0.74))

                Spacer(minLength: 8)

                Text(Self.time(date))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
        }
        .buttonStyle(PlayerRowButtonStyle())
        .accessibilityLabel(Text(GroupPaymentView.trainingDate(date)))
        .accessibilityValue(optionCount > 0 ? "\(statusTitle ?? ""). Вариантов: \(optionCount)" : statusTitle ?? training.bookingLabel ?? "")
        .accessibilityHint(optionCount > 0 ? "Открывает выбор времени" : "")
    }

    fileprivate static func weekday(_ date: Date) -> String {
        date.formatted(dateFormat.weekday(.wide)).capitalized
    }

    fileprivate static func time(_ date: Date) -> String {
        date.formatted(dateFormat.hour().minute())
    }
}

private struct TrainingLocationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let court: TrainingCourt
    var usesShortAddress = false

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(court.name)
                    .font(.subheadline.weight(.semibold))
                Text(usesShortAddress ? court.shortAddress ?? court.address : court.address)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = court.directions {
                Link(destination: url) {
                    Label("Маршрут", systemImage: "location")
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .tint(.white)
            }
        }
        .padding(.vertical, 12)
    }
}

struct TrainingDetails: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let training: ScheduledTraining
    let referenceDate: Date?
    let paidMonths: [Date: TrainingFrequency]
    let makeupSlots: [Date]
    let sessions: [ScheduledTraining]
    let account: LocalPlayerAccount
    @Binding var cancellations: [Date: TrainingCancellation]
    @State private var offer: TrainingCancellation?
    @State private var confirmationAvailableAt: ContinuousClock.Instant?
    @State private var conditionsChanged = false
    @State private var confirmsReplacementDecline = false
    @State private var selectedReplacement: Date?
    @State private var unavailableReplacement: Date?
    @State private var showsSupport = false
    @ScaledMetric(relativeTo: .body) private var heightScale: CGFloat = 1

    private static let confirmationTransition = Animation.easeOut(duration: 0.16)
    private static let cancellationTransition = Animation.easeOut(duration: 0.20)

    init(training: ScheduledTraining, referenceDate: Date?, paidMonths: [Date: TrainingFrequency],
         makeupSlots: [Date], sessions: [ScheduledTraining],
         cancellations: Binding<[Date: TrainingCancellation]>, account: LocalPlayerAccount) {
        self.training = training
        self.referenceDate = referenceDate
        self.paidMonths = paidMonths
        self.makeupSlots = makeupSlots
        self.sessions = sessions
        self.account = account
        _cancellations = cancellations
    }

    private var status: TrainingCancellation? { cancellations[training.id] ?? training.clubCancellation }
    private var cancellation: TrainingCancellation? {
        TrainingCancellation.playerCancellation(for: training.startsAt, at: referenceDate ?? .now)
    }
    private var pendingCancellation: TrainingCancellation? { status == nil ? offer : nil }
    private var schedule: PlayerSchedule {
        PlayerSchedule(sessions: sessions, paidMonths: paidMonths, makeupSlots: makeupSlots, cancellations: cancellations)
    }
    private var isMakeup: Bool { status?.hasOpenMakeup == true }
    private var makeupHasExpired: Bool {
        isMakeup && schedule.makeupDeadline(for: training.id) <= (referenceDate ?? .now)
    }
    private var options: [Date] {
        if isMakeup { return schedule.makeupOptions(for: training, at: referenceDate ?? .now) }
        return status?.replacementDates ?? []
    }
    private var showsCompactBooking: Bool {
        isMakeup || !options.isEmpty || status == .clubReplacementDeclined
    }

    private var sheetHeight: CGFloat {
        if confirmsReplacementDecline { return 326 }
        if !options.isEmpty { return (isMakeup ? 356 : 334) + CGFloat(options.count) * 52 }
        if isMakeup { return 350 }
        if status == .clubReplacementDeclined { return 350 }
        if status == .clubAwaitingReplacement { return 398 }
        if status != nil { return 362 }
        let base: CGFloat = cancellation == .withMakeup ? 396 : 334
        return base + (training.bookingLabel == nil ? 0 : 26)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView {
                    VStack(spacing: 12) {
                        dateHeader
                            .frame(maxWidth: 460, alignment: .leading)
                            .padding(.horizontal, 24)
                            .frame(maxWidth: .infinity)
                        sheetContent
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
                .scrollBounceBehavior(.basedOnSize)

                footer
                    .frame(maxWidth: 460)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle("Тренировка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if pendingCancellation != nil || confirmsReplacementDecline {
                        Button("Назад к тренировке", systemImage: "chevron.backward") {
                            offer = nil
                            confirmsReplacementDecline = false
                        }
                            .labelStyle(.iconOnly)
                    } else if !showsContactInFooter {
                        Button("Написать в поддержку", systemImage: "message", action: openSupport)
                            .labelStyle(.iconOnly)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if pendingCancellation == nil && !confirmsReplacementDecline {
                        Button("Закрыть", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .navigationDestination(isPresented: $showsSupport) {
                PlayerSupportView(account: account)
                    .navigationTitle("Поддержка")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .presentationDetents(detents)
    }

    private var detents: Set<PresentationDetent> {
        if showsSupport || dynamicTypeSize.isAccessibilitySize { return [.large] }
        return [.height(sheetHeight * heightScale)]
    }

    private func openSupport() {
        account.draftTopic = .training(training)
        showsSupport = true
    }

    private var sheetContent: some View {
        ZStack(alignment: .topLeading) {
            if let outcome = pendingCancellation {
                confirmation(outcome)
                    .transition(.opacity)
            } else {
                details
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .clipped()
        .padelAnimation(Self.cancellationTransition, value: offer)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        if confirmsReplacementDecline || !options.isEmpty {
            replacementActions(options)
        } else if showsContactInFooter {
            contactButton
        } else if status == nil, cancellation != nil {
            cancellationButton
        }
    }

    private var showsContactInFooter: Bool {
        options.isEmpty && ((isMakeup && !makeupHasExpired) ||
            status == .clubReplacementDeclined || status == .clubAwaitingReplacement)
    }

    private var dateHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(training.startsAt.formatted(HomeView.dateFormat.day().month(.wide)))
                .font(.display(.largeTitle, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    dateAndTime
                    if showsCompactBooking { compactCourt }
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 5) {
                    dateAndTime
                    if showsCompactBooking { Text(training.court.name).font(.subheadline) }
                }
            }
            .foregroundStyle(.white.opacity(0.74))
            if let bookingLabel = training.bookingLabel {
                Text(bookingLabel)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.74))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var dateAndTime: some View {
        Text("\(HomeView.weekday(training.startsAt)) · \(HomeView.time(training.startsAt))")
            .font(.headline)
    }

    private var compactCourt: some View {
        Text("· \(training.court.name)")
            .font(.subheadline)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !showsCompactBooking {
                TrainingLocationRow(court: training.court, usesShortAddress: true)
                    .padding(.horizontal, 14)
                    .background { locationBackground }
                    .clipShape(.rect(cornerRadius: 18))
            }

            if let status {
                statusDetails(status)
            } else if let available = cancellation {
                if available == .withMakeup || conditionsChanged {
                    Text(available == .withMakeup ? deadlineText : "Срок отмены с отработкой истёк.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.74))
                }
            } else if conditionsChanged {
                Text("Тренировка уже началась.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.74))
            }
        }
    }

    private var locationBackground: some View {
        ZStack {
            Color.white.opacity(0.07)
            if let asset = training.court.photoAsset {
                GeometryReader { geometry in
                    Image(asset)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .saturation(0.35)
                }
                LinearGradient(colors: [.black.opacity(0.91), .black.opacity(0.24)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .accessibilityHidden(true)
    }

    private func statusDetails(_ status: TrainingCancellation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(makeupHasExpired ? "Срок отработки истёк" : status.title)
                .font(.headline)
                .foregroundStyle(status.needsAttention ? Theme.warningOnDark : .white)

            if isMakeup && !makeupHasExpired && !confirmsReplacementDecline {
                let deadline = HomeView.calendar.date(byAdding: .day, value: -1, to: schedule.makeupDeadline(for: training.id))!
                Text("До \(deadline.formatted(HomeView.dateFormat.day().month(.wide))) включительно")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.74))
            }

            if confirmsReplacementDecline || !options.isEmpty {
                if confirmsReplacementDecline {
                    Text("Попросите поддержку подобрать другое время.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.74))
                } else {
                    replacementOptions(options)
                }
            } else {
                if !makeupHasExpired {
                    Text(statusMessage(status))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.74))
                }
            }
        }
        .padelAnimation(Self.confirmationTransition, value: confirmsReplacementDecline)
    }

    private func canAcceptReplacement(on date: Date) -> Bool {
        let now = referenceDate ?? .now
        if isMakeup { return schedule.makeupOptions(for: training, at: now).contains(date) }
        return date > now && !schedule.sessionsWithBookings.contains { $0.id == date }
    }

    private func replacementOptions(_ dates: [Date]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isMakeup ? "Даты отработки" : "Даты замены")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.74))

            ForEach(dates.sorted(), id: \.self) { date in
                let selected = selectedReplacement == date
                let available = canAcceptReplacement(on: date)
                Button {
                    selectedReplacement = date
                    unavailableReplacement = nil
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .accessibilityHidden(true)
                        Text(date.formatted(HomeView.dateFormat.day().month(.wide)))
                        Spacer()
                        Text(available ? HomeView.time(date) : "Мест нет")
                            .monospacedDigit()
                    }
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(available ? 1 : 0.45))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(.white.opacity(selected ? 0.18 : 0.07), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(PlayerRowButtonStyle(cornerRadius: 12))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .disabled(!available)
            }

            if unavailableReplacement != nil {
                Text("Это время уже недоступно. Выберите другое.")
                    .font(.footnote)
                    .foregroundStyle(Theme.warningOnDark)
            }
        }
    }

    private func replacementActions(_ dates: [Date]) -> some View {
        VStack(spacing: 2) {
            replacementButtons(dates)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        .padelAnimation(Self.confirmationTransition, value: confirmsReplacementDecline)
    }

    @ViewBuilder
    private func replacementButtons(_ dates: [Date]) -> some View {
        if confirmsReplacementDecline {
            Button(role: .destructive) {
                guard let confirmationAvailableAt, ContinuousClock().now >= confirmationAvailableAt else { return }
                if status == .withMakeup, !makeupHasExpired {
                    cancellations[training.id] = .makeupDatesDeclined
                } else if status == .clubReplacement(dates) {
                    cancellations[training.id] = .clubReplacementDeclined
                }
                confirmsReplacementDecline = false
            } label: {
                Text("Подтвердить")
                    .foregroundStyle(Theme.warningOnDark)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(.white)

        } else {
            Button {
                guard status == .withMakeup || status == .clubReplacement(dates),
                      let date = selectedReplacement, dates.contains(date) else { return }
                guard canAcceptReplacement(on: date) else {
                    selectedReplacement = nil
                    unavailableReplacement = date
                    return
                }
                cancellations[training.id] = isMakeup ? .makeupBooked(date) : .clubReplacementAccepted(date)
                dismiss()
            } label: {
                Text("Подтвердить запись").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .disabled(selectedReplacement == nil)

            Button {
                confirmationAvailableAt = ContinuousClock().now.advanced(by: .milliseconds(250))
                confirmsReplacementDecline = true
            } label: {
                Text("Время не подходит")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .frame(minHeight: 44)
        }
    }

    private var contactButton: some View {
        Button(action: openSupport) {
            Label("Написать в поддержку", systemImage: "message")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.white)
    }

    private func confirmation(_ outcome: TrainingCancellation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(outcome == .withMakeup ? "Занятие сохраним для отработки" : "Занятие спишется из абонемента")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(outcome == .withMakeup
                ? "После отмены можно выбрать время отработки в расписании."
                : "До начала меньше суток. Отработки не будет.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.74))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.07), in: .rect(cornerRadius: 18))
    }

    private var cancellationButton: some View {
        Button(role: pendingCancellation == nil ? nil : .destructive) {
            if let outcome = pendingCancellation {
                confirm(outcome)
            } else {
                offer = cancellation
                confirmationAvailableAt = ContinuousClock().now.advanced(by: .milliseconds(250))
                conditionsChanged = offer == nil
            }
        } label: {
            ZStack {
                if pendingCancellation == nil {
                    Text("Отменить запись")
                        .transition(.opacity)
                } else {
                    Text("Подтвердить отмену")
                        .transition(.opacity)
                }
            }
            .foregroundStyle(Theme.warningOnDark)
            .frame(maxWidth: .infinity)
            .clipped()
            .padelAnimation(Self.cancellationTransition, value: offer)
        }
        .buttonStyle(.glass)
        .tint(.white)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }

    private func confirm(_ expected: TrainingCancellation) {
        // The confirmation replaces the first button in place. A double tap must only open it.
        guard let confirmationAvailableAt, ContinuousClock().now >= confirmationAvailableAt else { return }
        defer { offer = nil }
        guard status == nil else { return }
        guard TrainingCancellation.playerCancellation(for: training.startsAt, at: referenceDate ?? .now) == expected else {
            conditionsChanged = true
            return
        }
        if expected == .withMakeup, training.isMakeup, let original = training.replaces,
           cancellations[original] == .makeupBooked(training.id) {
            cancellations[original] = .withMakeup
            dismiss()
        } else {
            cancellations[training.id] = expected
        }
    }

    private var deadlineText: String {
        let deadline = TrainingCancellation.deadline(for: training.startsAt)
        let date = deadline.formatted(HomeView.dateFormat.day().month(.wide))
        return "Отмена с отработкой до \(date), \(HomeView.time(deadline))."
    }

    private func statusMessage(_ status: TrainingCancellation) -> String {
        switch status {
        case .withMakeup: "Нет свободных дат."
        case let .makeupBooked(date): "Вы записаны на \(GroupPaymentView.trainingDate(date))."
        case .makeupDatesDeclined: "Ни одна дата не подошла. Выберите другое время с администратором."
        case .late: "Вы сообщили об отсутствии менее чем за 24 часа."
        case .clubReplacement: "Предложена замена."
        case let .clubReplacementAccepted(date): "Замена в расписании. \(GroupPaymentView.trainingDate(date).capitalized)."
        case .clubReplacementDeclined: "Ни одна дата не подошла. Выберите другое время с администратором."
        case .clubAwaitingReplacement: "Администратор предложит новую дату."
        }
    }
}
