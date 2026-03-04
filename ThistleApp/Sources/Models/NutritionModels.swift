import Foundation
import SwiftUI

enum DietProfile: String, CaseIterable, Identifiable, Codable {
    case whole30 = "Whole30"
    case pescatarian = "Pescatarian"
    case vegan = "Vegan"
    case keto = "Keto"
    case paleo = "Paleo"

    var id: String { rawValue }
}

enum ComplianceRating: String, CaseIterable, Codable {
    case green
    case yellow
    case red

    var title: String {
        switch self {
        case .green: "Fits"
        case .yellow: "Caution"
        case .red: "Avoid"
        }
    }

    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .orange
        case .red: .red
        }
    }
}

enum IngredientFlagSeverity: String, Codable {
    case good
    case caution
    case avoid

    var color: Color {
        switch self {
        case .good: .green
        case .caution: .orange
        case .avoid: .red
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .good: .medium
        case .caution, .avoid: .bold
        }
    }
}

struct NutritionFacts: Codable, Hashable {
    var calories: Int
    var protein: Double
    var carbs: Double
    var fat: Double

    static let zero = NutritionFacts(calories: 0, protein: 0, carbs: 0, fat: 0)

    static func + (lhs: NutritionFacts, rhs: NutritionFacts) -> NutritionFacts {
        NutritionFacts(
            calories: lhs.calories + rhs.calories,
            protein: lhs.protein + rhs.protein,
            carbs: lhs.carbs + rhs.carbs,
            fat: lhs.fat + rhs.fat
        )
    }

    static func * (lhs: NutritionFacts, rhs: Double) -> NutritionFacts {
        NutritionFacts(
            calories: Int((Double(lhs.calories) * rhs).rounded()),
            protein: lhs.protein * rhs,
            carbs: lhs.carbs * rhs,
            fat: lhs.fat * rhs
        )
    }
}

struct IngredientFlag: Identifiable, Hashable {
    let id = UUID()
    var ingredient: String
    var severity: IngredientFlagSeverity
    var reason: String
}

struct ProductAnalysis: Hashable {
    var rating: ComplianceRating
    var summary: String
    var flags: [IngredientFlag]
}

struct Product: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var brand: String
    var barcode: String
    var stores: [String]
    var servingDescription: String
    var ingredients: [String]
    var nutrition: NutritionFacts
}

struct MacroGoals: Codable, Hashable {
    var calories: Int
    var protein: Double
    var carbs: Double
    var fat: Double

    static let `default` = MacroGoals(calories: 1800, protein: 120, carbs: 140, fat: 70)
}

struct LoggedFood: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var servingText: String
    var sourceProductIDs: [UUID]
    var nutrition: NutritionFacts
    var analysis: ProductAnalysis
    var loggedAt: Date
}

struct MealComponent: Identifiable, Hashable {
    let id = UUID()
    var product: Product
    var servings: Double
}

struct SavedMeal: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var components: [MealComponent]

    var nutrition: NutritionFacts {
        components.reduce(.zero) { partial, component in
            partial + (component.product.nutrition * component.servings)
        }
    }
}
