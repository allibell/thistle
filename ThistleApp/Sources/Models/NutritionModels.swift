import Foundation
import SwiftUI

enum ProductSource: String, Codable, Hashable {
    case seed
    case openFoodFacts
    case upcItemDB
    case usda
    case deepSearch
}

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
        case .green: ThistleTheme.primaryGreen
        case .yellow: ThistleTheme.warning
        case .red: ThistleTheme.danger
        }
    }
}

enum IngredientFlagSeverity: String, Codable {
    case good
    case caution
    case avoid

    var color: Color {
        switch self {
        case .good: ThistleTheme.primaryGreen
        case .caution: ThistleTheme.warning
        case .avoid: ThistleTheme.danger
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

struct IngredientFlag: Identifiable, Hashable, Codable {
    var id: String
    var ingredient: String
    var severity: IngredientFlagSeverity
    var reason: String

    init(id: String = UUID().uuidString, ingredient: String, severity: IngredientFlagSeverity, reason: String) {
        self.id = id
        self.ingredient = ingredient
        self.severity = severity
        self.reason = reason
    }
}

struct ProductAnalysis: Hashable, Codable {
    var rating: ComplianceRating
    var summary: String
    var flags: [IngredientFlag]
}

struct Product: Identifiable, Hashable, Codable {
    var id: String
    var source: ProductSource
    var name: String
    var brand: String
    var barcode: String
    var stores: [String]
    var servingDescription: String
    var ingredients: [String]
    var nutrition: NutritionFacts
    var imageURL: URL?
    var lastUpdatedAt: Date

    init(
        id: String? = nil,
        source: ProductSource,
        name: String,
        brand: String,
        barcode: String,
        stores: [String],
        servingDescription: String,
        ingredients: [String],
        nutrition: NutritionFacts,
        imageURL: URL? = nil,
        lastUpdatedAt: Date = .now
    ) {
        self.source = source
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.stores = stores
        self.servingDescription = servingDescription
        self.ingredients = ingredients
        self.nutrition = nutrition
        self.imageURL = imageURL
        self.lastUpdatedAt = lastUpdatedAt
        self.id = id ?? Product.makeID(source: source, barcode: barcode, name: name, brand: brand)
    }

    static func makeID(source: ProductSource, barcode: String, name: String, brand: String) -> String {
        let safeBarcode = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !safeBarcode.isEmpty {
            return "\(source.rawValue):\(safeBarcode)"
        }
        let slug = "\(brand)-\(name)"
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(source.rawValue):\(slug)"
    }

    var hasIngredientDetails: Bool {
        ingredients.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var hasMeaningfulNutrition: Bool {
        nutrition.calories > 0 || nutrition.protein > 0 || nutrition.carbs > 0 || nutrition.fat > 0
    }

    var dataCompletenessScore: Int {
        var score = 0
        if hasIngredientDetails { score += 4 }
        if hasMeaningfulNutrition { score += 3 }
        if !barcode.isEmpty { score += 1 }
        if !brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, brand != "Unknown Brand" { score += 1 }
        if !servingDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, servingDescription != "1 serving" { score += 1 }
        if !stores.isEmpty { score += 1 }
        if imageURL != nil { score += 1 }
        return score
    }

    var isLowConfidenceCatalogEntry: Bool {
        dataCompletenessScore < 4
    }

    var canonicalLookupKey: String {
        let digits = barcode.filter(\.isNumber)
        if !digits.isEmpty {
            return "barcode:\(digits)"
        }

        let slug = "\(brand)-\(name)"
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "name:\(slug)"
    }
}

struct MacroGoals: Codable, Hashable {
    var calories: Int
    var protein: Double
    var carbs: Double
    var fat: Double

    static let `default` = MacroGoals(calories: 1800, protein: 120, carbs: 140, fat: 70)

    var proteinCalories: Double { protein * 4 }
    var carbCalories: Double { carbs * 4 }
    var fatCalories: Double { fat * 9 }

    var proteinPercent: Int {
        percentage(forCalories: proteinCalories)
    }

    var carbPercent: Int {
        percentage(forCalories: carbCalories)
    }

    var fatPercent: Int {
        percentage(forCalories: fatCalories)
    }

    mutating func setMacroPercents(protein proteinPercent: Int, carbs carbPercent: Int, fat fatPercent: Int) {
        let safeProtein = max(0, proteinPercent)
        let safeCarbs = max(0, carbPercent)
        let safeFat = max(0, fatPercent)

        protein = grams(forPercent: safeProtein, caloriesPerGram: 4)
        carbs = grams(forPercent: safeCarbs, caloriesPerGram: 4)
        fat = grams(forPercent: safeFat, caloriesPerGram: 9)
    }

    private func percentage(forCalories macroCalories: Double) -> Int {
        guard calories > 0 else { return 0 }
        return Int(((macroCalories / Double(calories)) * 100).rounded())
    }

    private func grams(forPercent percent: Int, caloriesPerGram: Double) -> Double {
        let allocatedCalories = (Double(calories) * Double(percent)) / 100
        return allocatedCalories / caloriesPerGram
    }
}

struct DeepSearchFieldDiff: Identifiable, Hashable, Codable {
    enum Kind: String, Codable, Hashable {
        case name
        case brand
        case barcode
        case serving
        case stores
        case ingredients
        case macros
        case image
    }

    var id: String { kind.rawValue }
    var kind: Kind
    var label: String
    var oldValue: String
    var newValue: String
    var addsMissingData: Bool
}

struct DeepSearchProposal: Identifiable, Hashable, Codable {
    var id: String
    var productID: String
    var candidateProduct: Product
    var mergedProduct: Product
    var scope: String
    var confidenceScore: Int
    var confidenceReasons: [String]
    var changedFields: [DeepSearchFieldDiff]

    init(
        id: String = UUID().uuidString,
        productID: String,
        candidateProduct: Product,
        mergedProduct: Product,
        scope: String,
        confidenceScore: Int,
        confidenceReasons: [String],
        changedFields: [DeepSearchFieldDiff]
    ) {
        self.id = id
        self.productID = productID
        self.candidateProduct = candidateProduct
        self.mergedProduct = mergedProduct
        self.scope = scope
        self.confidenceScore = confidenceScore
        self.confidenceReasons = confidenceReasons
        self.changedFields = changedFields
    }
}

struct LoggedFood: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var servingText: String
    var sourceProductIDs: [String]
    var nutrition: NutritionFacts
    var analysis: ProductAnalysis
    var loggedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        servingText: String,
        sourceProductIDs: [String],
        nutrition: NutritionFacts,
        analysis: ProductAnalysis,
        loggedAt: Date
    ) {
        self.id = id
        self.title = title
        self.servingText = servingText
        self.sourceProductIDs = sourceProductIDs
        self.nutrition = nutrition
        self.analysis = analysis
        self.loggedAt = loggedAt
    }
}

struct MealComponent: Identifiable, Hashable, Codable {
    var id: String
    var product: Product
    var servings: Double

    init(id: String = UUID().uuidString, product: Product, servings: Double) {
        self.id = id
        self.product = product
        self.servings = servings
    }
}

struct SavedMeal: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var components: [MealComponent]

    init(id: String = UUID().uuidString, name: String, components: [MealComponent]) {
        self.id = id
        self.name = name
        self.components = components
    }

    var nutrition: NutritionFacts {
        components.reduce(.zero) { partial, component in
            partial + (component.product.nutrition * component.servings)
        }
    }
}

struct PersistedAppState: Codable {
    var selectedDiet: DietProfile
    var goals: MacroGoals
    var cachedProducts: [Product]
    var meals: [SavedMeal]
    var loggedFoods: [LoggedFood]
    var usageCounts: [String: Int]
    var searchCacheByQuery: [String: CachedProductList]
    var barcodeCache: [String: CachedProductValue]
    var deepSearchCache: [String: CachedProductValue]

    init(
        selectedDiet: DietProfile,
        goals: MacroGoals,
        cachedProducts: [Product],
        meals: [SavedMeal],
        loggedFoods: [LoggedFood],
        usageCounts: [String: Int],
        searchCacheByQuery: [String: CachedProductList] = [:],
        barcodeCache: [String: CachedProductValue] = [:],
        deepSearchCache: [String: CachedProductValue] = [:]
    ) {
        self.selectedDiet = selectedDiet
        self.goals = goals
        self.cachedProducts = cachedProducts
        self.meals = meals
        self.loggedFoods = loggedFoods
        self.usageCounts = usageCounts
        self.searchCacheByQuery = searchCacheByQuery
        self.barcodeCache = barcodeCache
        self.deepSearchCache = deepSearchCache
    }

    private enum CodingKeys: String, CodingKey {
        case selectedDiet
        case goals
        case cachedProducts
        case meals
        case loggedFoods
        case usageCounts
        case searchCacheByQuery
        case barcodeCache
        case deepSearchCache
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedDiet = try container.decodeIfPresent(DietProfile.self, forKey: .selectedDiet) ?? .whole30
        goals = try container.decodeIfPresent(MacroGoals.self, forKey: .goals) ?? .default
        cachedProducts = try container.decodeIfPresent([Product].self, forKey: .cachedProducts) ?? []
        meals = try container.decodeIfPresent([SavedMeal].self, forKey: .meals) ?? []
        loggedFoods = try container.decodeIfPresent([LoggedFood].self, forKey: .loggedFoods) ?? []
        usageCounts = try container.decodeIfPresent([String: Int].self, forKey: .usageCounts) ?? [:]
        searchCacheByQuery = try container.decodeIfPresent([String: CachedProductList].self, forKey: .searchCacheByQuery) ?? [:]
        barcodeCache = try container.decodeIfPresent([String: CachedProductValue].self, forKey: .barcodeCache) ?? [:]
        deepSearchCache = try container.decodeIfPresent([String: CachedProductValue].self, forKey: .deepSearchCache) ?? [:]
    }
}

struct CachedProductList: Codable, Hashable {
    var products: [Product]
    var cachedAt: Date
}

struct CachedProductValue: Codable, Hashable {
    var product: Product?
    var cachedAt: Date
}
