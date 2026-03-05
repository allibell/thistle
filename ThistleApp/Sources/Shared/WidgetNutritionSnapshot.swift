import Foundation

struct WidgetNutritionSnapshot: Codable, Hashable {
    struct MetricProgress: Codable, Hashable {
        var consumed: Double
        var goal: Double

        var completion: Double {
            guard goal > 0 else { return 0 }
            return consumed / goal
        }
    }

    var updatedAt: Date
    var calories: MetricProgress
    var protein: MetricProgress
    var carbs: MetricProgress
    var fat: MetricProgress
    var fiber: MetricProgress

    static let appGroupID = "group.com.allibell.thistle"
    static let storageKey = "nutritionGoalsSnapshotV1"

    static let placeholder = WidgetNutritionSnapshot(
        updatedAt: .now,
        calories: MetricProgress(consumed: 1260, goal: 1800),
        protein: MetricProgress(consumed: 82, goal: 120),
        carbs: MetricProgress(consumed: 97, goal: 140),
        fat: MetricProgress(consumed: 48, goal: 70),
        fiber: MetricProgress(consumed: 17, goal: 28)
    )
}

enum WidgetNutritionMetric: String, CaseIterable, Identifiable {
    case calories
    case protein
    case carbs
    case fat
    case fiber

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calories: return "Calories"
        case .protein: return "Protein"
        case .carbs: return "Carbs"
        case .fat: return "Fat"
        case .fiber: return "Fiber"
        }
    }

    func value(in snapshot: WidgetNutritionSnapshot) -> WidgetNutritionSnapshot.MetricProgress {
        switch self {
        case .calories: return snapshot.calories
        case .protein: return snapshot.protein
        case .carbs: return snapshot.carbs
        case .fat: return snapshot.fat
        case .fiber: return snapshot.fiber
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .calories:
            return Int(value.rounded()).formatted()
        case .protein, .carbs, .fat, .fiber:
            return "\(value.formatted(.number.precision(.fractionLength(0...1))))g"
        }
    }
}
