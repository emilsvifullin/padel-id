import Foundation

/// Human-readable bands of the 0–7 padel level scale.
nonisolated enum LevelBand: CaseIterable, Sendable {
    case beginner, novice, recreational, intermediate, advanced, competitive, elite

    init(level: Double) {
        switch level {
        case ..<1.0: self = .beginner
        case ..<2.0: self = .novice
        case ..<3.0: self = .recreational
        case ..<4.0: self = .intermediate
        case ..<5.0: self = .advanced
        case ..<6.0: self = .competitive
        default: self = .elite
        }
    }

    var title: String {
        switch self {
        case .beginner: "Новичок"
        case .novice: "Начинающий"
        case .recreational: "Любитель"
        case .intermediate: "Средний уровень"
        case .advanced: "Продвинутый"
        case .competitive: "Турнирный"
        case .elite: "Профессионал"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .beginner: 0...1
        case .novice: 1...2
        case .recreational: 2...3
        case .intermediate: 3...4
        case .advanced: 4...5
        case .competitive: 5...6
        case .elite: 6...7
        }
    }

    var description: String {
        switch self {
        case .beginner: "Первые игры, знакомство с правилами и стеклом."
        case .novice: "Держит мяч в игре, учится выходить к сетке."
        case .recreational: "Регулярные игры, уверенные базовые удары."
        case .intermediate: "Играет от стекла, использует свечи и воллеи."
        case .advanced: "Контролирует темп, бандеха и вибора в арсенале."
        case .competitive: "Регулярные турниры высокого уровня."
        case .elite: "Профессиональный и околопрофессиональный уровень."
        }
    }
}

nonisolated enum ReliabilityBand: Sendable {
    case low, medium, high

    init(_ reliability: Int) {
        switch reliability {
        case ..<40: self = .low
        case ..<70: self = .medium
        default: self = .high
        }
    }

    var title: String {
        switch self {
        case .low: "Низкая"
        case .medium: "Средняя"
        case .high: "Высокая"
        }
    }
}

nonisolated enum Confidence: Sendable {
    case low, medium, high

    init(_ value: Double) {
        switch value {
        case ..<0.3: self = .low
        case ..<0.6: self = .medium
        default: self = .high
        }
    }

    var title: String {
        switch self {
        case .low: "Мало данных"
        case .medium: "Средняя достоверность"
        case .high: "Высокая достоверность"
        }
    }
}
