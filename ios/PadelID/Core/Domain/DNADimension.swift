import Foundation

/// The six Padel DNA dimensions with their presentation metadata.
nonisolated enum DNADimension: String, CaseIterable, Identifiable, Sendable, Hashable {
    case serveReturn = "serve_return"
    case defense = "defense"
    case transitionLob = "transition_lob"
    case netGame = "net_game"
    case overheads = "overheads"
    case consistencyDecisions = "consistency_decisions"

    var id: String { rawValue }

    /// Accepts the canonical snake_case key and the camelCase form produced by
    /// key conversion of dictionary payloads.
    init?(apiKey: String) {
        if let value = DNADimension(rawValue: apiKey) {
            self = value
        } else if let value = DNADimension.allCases.first(where: { $0.camelKey == apiKey }) {
            self = value
        } else {
            return nil
        }
    }

    var camelKey: String {
        let parts = rawValue.split(separator: "_")
        return parts.enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
    }

    var title: String {
        switch self {
        case .serveReturn: "Подача и приём"
        case .defense: "Защита"
        case .transitionLob: "Переход и свечи"
        case .netGame: "Игра у сетки"
        case .overheads: "Удары над головой"
        case .consistencyDecisions: "Стабильность и решения"
        }
    }

    var shortTitle: String {
        switch self {
        case .serveReturn: "Подача"
        case .defense: "Защита"
        case .transitionLob: "Переход"
        case .netGame: "Сетка"
        case .overheads: "Смэши"
        case .consistencyDecisions: "Решения"
        }
    }

    var symbol: String {
        switch self {
        case .serveReturn: "arrow.uturn.forward"
        case .defense: "shield.lefthalf.filled"
        case .transitionLob: "arrow.up.forward.and.arrow.down.backward"
        case .netGame: "square.grid.3x3.middle.filled"
        case .overheads: "bolt.fill"
        case .consistencyDecisions: "brain.head.profile"
        }
    }

    var explanation: String {
        switch self {
        case .serveReturn: "Качество подачи и надёжность приёма: глубина, направление, первый мяч розыгрыша."
        case .defense: "Игра от стекла и с задней линии: отбой после одного и двух стёкол, сохранение мяча в игре."
        case .transitionLob: "Выход к сетке из защиты: свечи, чикиты, смена ролей пары в розыгрыше."
        case .netGame: "Позиция у сетки: удары с лёта, перехват, давление на соперников."
        case .overheads: "Бандеха, вибора и смэши: контроль высоких мячей и завершение розыгрыша."
        case .consistencyDecisions: "Ошибки, выбор удара и игра в концовках: тай-брейки и решающие сеты."
        }
    }

    var trainingFocus: String {
        switch self {
        case .serveReturn: "Отработайте глубокую подачу в стекло и приём в ноги выходящему к сетке сопернику."
        case .defense: "Добавьте упражнения на отбой после стекла: сначала одиночное стекло, затем двойное и угловое."
        case .transitionLob: "Тренируйте высокую свечу через сетку соперников и быстрый выход вдвоём к сетке после неё."
        case .netGame: "Работайте над позицией у сетки: короткий замах на воллее и удары в ноги и в середину."
        case .overheads: "Сфокусируйтесь на бандехе: контроль глубины важнее силы, смэш — только по высоким мячам у сетки."
        case .consistencyDecisions: "Играйте розыгрыши на счёт с ограничением ошибок и тренируйте тай-брейки."
        }
    }
}

nonisolated enum DNAArchetype: String, Sendable {
    case forming
    case allRounder = "all_rounder"
    case netDominator = "net_dominator"
    case finisher
    case wall
    case architect
    case returner
    case strategist

    var title: String {
        switch self {
        case .forming: "Стиль формируется"
        case .allRounder: "Универсал"
        case .netDominator: "Хозяин сетки"
        case .finisher: "Финишёр"
        case .wall: "Стена"
        case .architect: "Архитектор розыгрыша"
        case .returner: "Мастер приёма"
        case .strategist: "Стратег"
        }
    }

    var summary: String {
        switch self {
        case .forming: "Сыграйте несколько подтверждённых матчей и попросите партнёров отметить ваши сильные стороны."
        case .allRounder: "Ровный профиль без выраженных слабостей — подходит к партнёру любого стиля."
        case .netDominator: "Сильнее всего у сетки: перехват инициативы и игра с лёта."
        case .finisher: "Завершает розыгрыши ударами над головой."
        case .wall: "Надёжная защита и игра от стекла — соперникам трудно пробить."
        case .architect: "Строит розыгрыш через свечи и переходы, меняя ритм игры."
        case .returner: "Задаёт тон с первого удара: сильная подача и приём."
        case .strategist: "Стабильность и точные решения, особенно в концовках."
        }
    }
}
