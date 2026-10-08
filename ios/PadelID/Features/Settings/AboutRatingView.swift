import SwiftUI

/// "Как устроены рейтинг и Padel DNA": a plain-language description of the
/// rating engine (PIR-1) and the Padel DNA model, consistent with the server.
struct AboutRatingView: View {
    @ScaledMetric(relativeTo: .subheadline) private var rangeWidth: CGFloat = 36

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                Text("Рейтинг показывает силу вашей игры по результатам подтверждённых матчей, а Padel DNA — из чего эта игра складывается.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                scaleBlock
                matchBlock
                reliabilityBlock
                fairPlayBlock
                dnaBlock
                dnaSourcesBlock
                confidenceBlock
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Рейтинг и Padel DNA")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Rating

    private var scaleBlock: some View {
        AboutRatingBlock(title: "Шкала уровня 0–7") {
            AboutRatingParagraph("Уровень — число от 0 до 7: чем выше, тем сильнее игра. Его определяют результаты матчей, а не отдельные удары, поэтому уровни разных игроков можно сравнивать между собой.")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(LevelBand.allCases, id: \.self) { band in
                    AboutRatingBandRow(band: band, rangeWidth: rangeWidth)
                }
            }
            AboutRatingParagraph("Стартовый уровень рассчитывается по анкете при регистрации: опыт, частота игр, другие ракеточные виды спорта, игра от стекла и у сетки, турниры. Анкета не даёт больше 5 — дальше уровень определяют только рейтинговые матчи.")
        }
    }

    private var matchBlock: some View {
        AboutRatingBlock(title: "Как матч меняет рейтинг") {
            AboutRatingTerm(
                title: "Сила пар",
                text: "Сила пары — средний уровень двух партнёров с небольшим штрафом за разницу между ними: соперники обычно играют в более слабого.")
            AboutRatingTerm(
                title: "Ожидаемый результат",
                text: "По разнице сил пар и формату матча модель рассчитывает шансы на победу. При разнице в полуровня сильная пара выигрывает примерно три матча из четырёх, при разнице в целый уровень — девять из десяти.")
            AboutRatingTerm(
                title: "Фактический результат",
                text: "Рейтинг меняется тем сильнее, чем больше результат отличается от ожидания. Победа над более сильной парой даёт заметный рост, над заведомо более слабой — небольшой. С поражениями — наоборот.")
            AboutRatingTerm(
                title: "Счёт",
                text: "Если вы взяли больше геймов, чем предсказывала модель, победа принесёт больше, а поражение обойдётся дешевле. Счёт меняет размер изменения не больше чем на 30% и никогда не меняет его знак: победа не снижает рейтинг, поражение не повышает.")
            AboutRatingTerm(
                title: "Каждый из четырёх",
                text: "Изменение каждого игрока зависит от его вклада в силу пары и от того, насколько точен его рейтинг. За один матч уровень меняется не больше чем на 0.5.")
        }
    }

    private var reliabilityBlock: some View {
        AboutRatingBlock(title: "Неопределённость и надёжность") {
            AboutRatingParagraph("Кроме уровня, у каждого игрока есть неопределённость — насколько система уверена в оценке. У нового игрока она высокая, поэтому первые матчи двигают рейтинг сильно и он быстро находит своё место. С каждым подтверждённым рейтинговым матчем неопределённость снижается, а изменения становятся спокойнее.")
            AboutRatingParagraph("Неопределённость партнёра и соперников тоже учитывается: матч против игроков с неточным рейтингом меньше говорит о вашей силе и влияет слабее.")
            AboutRatingTerm(
                title: "Надёжность",
                text: "Та же неопределённость в процентах — от 0 до 100%. Она растёт с каждым рейтинговым матчем, быстрее всего — в матчах с игроками, чей рейтинг уже устоялся.")
            AboutRatingTerm(
                title: "Предварительный рейтинг",
                text: "Пока сыграно меньше пяти рейтинговых матчей или надёжность ниже 40%, рейтинг считается предварительным.")
            AboutRatingTerm(
                title: "Перерыв в игре",
                text: "После 14 дней без рейтинговых матчей неопределённость начинает медленно расти, а надёжность — снижаться, но не ниже 50%. Первый матч после паузы изменит рейтинг сильнее обычного.")
        }
    }

    private var fairPlayBlock: some View {
        AboutRatingBlock(title: "Защита от накруток") {
            AboutRatingTerm(
                title: "Подтверждение всеми",
                text: "Рейтинг меняют только рейтинговые матчи, подтверждённые всеми четырьмя игроками. Если кто-то оспорил результат, матч не учитывается, пока автор не исправит его и все не подтвердят.")
            AboutRatingTerm(
                title: "Сроки",
                text: "Рейтинговый матч можно внести не позже чем через 14 дней после игры. Если за 7 дней его не подтвердят все участники, он истекает.")
            AboutRatingTerm(
                title: "Повторные составы",
                text: "Повторные рейтинговые матчи тех же четырёх игроков в течение 30 дней весят меньше: второй учитывается на 67%, третий — на 50%, следующие — ещё меньше.")
            AboutRatingTerm(
                title: "Дневной лимит",
                text: "Не больше шести рейтинговых матчей в сутки на одного игрока.")
            AboutRatingTerm(
                title: "Товарищеские матчи",
                text: "Не меняют рейтинг, но входят в статистику, а отметки после них уточняют Padel DNA.")
        }
    }

    // MARK: Padel DNA

    private var dnaBlock: some View {
        AboutRatingBlock(title: "Padel DNA") {
            AboutRatingParagraph("Padel DNA описывает стиль игры по шести направлениям:")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(DNADimension.allCases) { dimension in
                    Label {
                        Text(dimension.title)
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: dimension.symbol)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            AboutRatingParagraph("Каждое направление показано на той же шкале 0–7 относительно вашего уровня: в среднем шесть направлений равны рейтингу. Padel DNA показывает сильные стороны и зоны роста, но не меняет сам рейтинг.")
        }
    }

    private var dnaSourcesBlock: some View {
        AboutRatingBlock(title: "Откуда берутся данные") {
            AboutRatingTerm(
                title: "Самооценка",
                text: "Ваша оценка каждого направления — от «Заметно слабее» до «Заметно сильнее» своего уровня. Это стартовая точка с небольшим весом; изменить её можно в аккаунте.")
            AboutRatingTerm(
                title: "Отметки партнёров и соперников",
                text: "В течение 14 дней после подтверждённого матча участники отмечают у каждого игрока до двух сильных сторон и одну зону роста. Отметки игроков с надёжным рейтингом весят больше, а игроков, которые ниже вас по уровню больше чем на 0.5, — меньше. Старые отметки постепенно теряют вес: примерно через 8 месяцев — вдвое.")
            AboutRatingTerm(
                title: "Оценки тренеров",
                text: "Подтверждённый тренер оценивает все шесть направлений по шкале 0–7 — это самый весомый источник. Учитывается последняя оценка каждого тренера: 180 дней она подтверждает навыки, затем её вес постепенно снижается.")
            AboutRatingTerm(
                title: "Упорные сеты",
                text: "Сеты 7:5, 7:6 и супертай-брейки из последних 40 подтверждённых матчей влияют на «Стабильность и решения», когда таких сетов не меньше четырёх: если вы выигрываете их чаще, чем ожидалось при соотношении сил, направление растёт.")
        }
    }

    private var confidenceBlock: some View {
        AboutRatingBlock(title: "Достоверность") {
            AboutRatingParagraph("Достоверность показывает, сколько данных стоит за каждым направлением. Одна самооценка даёт низкую достоверность, каждая отметка и оценка тренера её повышают.")
            AboutRatingParagraph("Пока данных мало, вместо стиля игры показывается «\(DNAArchetype.forming.title)».")
        }
    }
}

// MARK: - Building blocks

private struct AboutRatingBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title)
            SectionContainer {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
            }
        }
    }
}

private struct AboutRatingParagraph: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AboutRatingTerm: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct AboutRatingBandRow: View {
    let band: LevelBand
    let rangeWidth: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(rangeText)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
                .frame(minWidth: rangeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(band.title)
                    .font(.subheadline.weight(.semibold))
                Text(band.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(band.title), уровень от \(lower) до \(upper). \(band.description)")
    }

    private var lower: Int { Int(band.range.lowerBound) }
    private var upper: Int { Int(band.range.upperBound) }
    private var rangeText: String { "\(lower)–\(upper)" }
}
