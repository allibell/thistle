import Foundation
import SwiftUI

enum ProductSource: String, Codable, Hashable {
    case seed
    case openFoodFacts
    case upcItemDB
    case usda
    case deepSearch
    case manual
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

struct NutritionFacts: Codable, Hashable, Sendable {
    var calories: Int
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    var sugars: Double
    var addedSugars: Double
    var saturatedFat: Double
    var transFat: Double
    var cholesterolMg: Double
    var sodiumMg: Double
    var potassiumMg: Double
    var calciumMg: Double
    var ironMg: Double
    var vitaminDMcg: Double
    var vitaminCMg: Double

    init(
        calories: Int,
        protein: Double,
        carbs: Double,
        fat: Double,
        fiber: Double = 0,
        sugars: Double = 0,
        addedSugars: Double = 0,
        saturatedFat: Double = 0,
        transFat: Double = 0,
        cholesterolMg: Double = 0,
        sodiumMg: Double = 0,
        potassiumMg: Double = 0,
        calciumMg: Double = 0,
        ironMg: Double = 0,
        vitaminDMcg: Double = 0,
        vitaminCMg: Double = 0
    ) {
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.sugars = sugars
        self.addedSugars = addedSugars
        self.saturatedFat = saturatedFat
        self.transFat = transFat
        self.cholesterolMg = cholesterolMg
        self.sodiumMg = sodiumMg
        self.potassiumMg = potassiumMg
        self.calciumMg = calciumMg
        self.ironMg = ironMg
        self.vitaminDMcg = vitaminDMcg
        self.vitaminCMg = vitaminCMg
    }

    static let zero = NutritionFacts(calories: 0, protein: 0, carbs: 0, fat: 0, fiber: 0)

    static func + (lhs: NutritionFacts, rhs: NutritionFacts) -> NutritionFacts {
        NutritionFacts(
            calories: lhs.calories + rhs.calories,
            protein: lhs.protein + rhs.protein,
            carbs: lhs.carbs + rhs.carbs,
            fat: lhs.fat + rhs.fat,
            fiber: lhs.fiber + rhs.fiber,
            sugars: lhs.sugars + rhs.sugars,
            addedSugars: lhs.addedSugars + rhs.addedSugars,
            saturatedFat: lhs.saturatedFat + rhs.saturatedFat,
            transFat: lhs.transFat + rhs.transFat,
            cholesterolMg: lhs.cholesterolMg + rhs.cholesterolMg,
            sodiumMg: lhs.sodiumMg + rhs.sodiumMg,
            potassiumMg: lhs.potassiumMg + rhs.potassiumMg,
            calciumMg: lhs.calciumMg + rhs.calciumMg,
            ironMg: lhs.ironMg + rhs.ironMg,
            vitaminDMcg: lhs.vitaminDMcg + rhs.vitaminDMcg,
            vitaminCMg: lhs.vitaminCMg + rhs.vitaminCMg
        )
    }

    static func * (lhs: NutritionFacts, rhs: Double) -> NutritionFacts {
        NutritionFacts(
            calories: Int((Double(lhs.calories) * rhs).rounded()),
            protein: lhs.protein * rhs,
            carbs: lhs.carbs * rhs,
            fat: lhs.fat * rhs,
            fiber: lhs.fiber * rhs,
            sugars: lhs.sugars * rhs,
            addedSugars: lhs.addedSugars * rhs,
            saturatedFat: lhs.saturatedFat * rhs,
            transFat: lhs.transFat * rhs,
            cholesterolMg: lhs.cholesterolMg * rhs,
            sodiumMg: lhs.sodiumMg * rhs,
            potassiumMg: lhs.potassiumMg * rhs,
            calciumMg: lhs.calciumMg * rhs,
            ironMg: lhs.ironMg * rhs,
            vitaminDMcg: lhs.vitaminDMcg * rhs,
            vitaminCMg: lhs.vitaminCMg * rhs
        )
    }

    func fillingMissing(from candidate: NutritionFacts) -> NutritionFacts {
        NutritionFacts(
            calories: calories == 0 && candidate.calories > 0 ? candidate.calories : calories,
            protein: protein <= 0.0001 && candidate.protein > 0.0001 ? candidate.protein : protein,
            carbs: carbs <= 0.0001 && candidate.carbs > 0.0001 ? candidate.carbs : carbs,
            fat: fat <= 0.0001 && candidate.fat > 0.0001 ? candidate.fat : fat,
            fiber: fiber <= 0.0001 && candidate.fiber > 0.0001 ? candidate.fiber : fiber,
            sugars: sugars <= 0.0001 && candidate.sugars > 0.0001 ? candidate.sugars : sugars,
            addedSugars: addedSugars <= 0.0001 && candidate.addedSugars > 0.0001 ? candidate.addedSugars : addedSugars,
            saturatedFat: saturatedFat <= 0.0001 && candidate.saturatedFat > 0.0001 ? candidate.saturatedFat : saturatedFat,
            transFat: transFat <= 0.0001 && candidate.transFat > 0.0001 ? candidate.transFat : transFat,
            cholesterolMg: cholesterolMg <= 0.0001 && candidate.cholesterolMg > 0.0001 ? candidate.cholesterolMg : cholesterolMg,
            sodiumMg: sodiumMg <= 0.0001 && candidate.sodiumMg > 0.0001 ? candidate.sodiumMg : sodiumMg,
            potassiumMg: potassiumMg <= 0.0001 && candidate.potassiumMg > 0.0001 ? candidate.potassiumMg : potassiumMg,
            calciumMg: calciumMg <= 0.0001 && candidate.calciumMg > 0.0001 ? candidate.calciumMg : calciumMg,
            ironMg: ironMg <= 0.0001 && candidate.ironMg > 0.0001 ? candidate.ironMg : ironMg,
            vitaminDMcg: vitaminDMcg <= 0.0001 && candidate.vitaminDMcg > 0.0001 ? candidate.vitaminDMcg : vitaminDMcg,
            vitaminCMg: vitaminCMg <= 0.0001 && candidate.vitaminCMg > 0.0001 ? candidate.vitaminCMg : vitaminCMg
        )
    }

    var additionalNutritionFacts: [NutritionDetailFact] {
        [
            NutritionDetailFact(id: "sugars", label: "Sugars", value: sugars, unit: "g"),
            NutritionDetailFact(id: "addedSugars", label: "Added Sugars", value: addedSugars, unit: "g"),
            NutritionDetailFact(id: "saturatedFat", label: "Saturated Fat", value: saturatedFat, unit: "g"),
            NutritionDetailFact(id: "transFat", label: "Trans Fat", value: transFat, unit: "g"),
            NutritionDetailFact(id: "cholesterol", label: "Cholesterol", value: cholesterolMg, unit: "mg"),
            NutritionDetailFact(id: "sodium", label: "Sodium", value: sodiumMg, unit: "mg"),
            NutritionDetailFact(id: "potassium", label: "Potassium", value: potassiumMg, unit: "mg"),
            NutritionDetailFact(id: "calcium", label: "Calcium", value: calciumMg, unit: "mg"),
            NutritionDetailFact(id: "iron", label: "Iron", value: ironMg, unit: "mg"),
            NutritionDetailFact(id: "vitaminD", label: "Vitamin D", value: vitaminDMcg, unit: "mcg"),
            NutritionDetailFact(id: "vitaminC", label: "Vitamin C", value: vitaminCMg, unit: "mg")
        ]
        .filter { $0.value > 0.0001 }
    }

    var needsNutritionBackfill: Bool {
        let hasPrimary = calories > 0 || protein > 0 || carbs > 0 || fat > 0
        guard hasPrimary else { return false }
        return fiber <= 0.0001 || additionalNutritionFacts.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case calories
        case protein
        case carbs
        case fat
        case fiber
        case sugars
        case addedSugars
        case saturatedFat
        case transFat
        case cholesterolMg
        case sodiumMg
        case potassiumMg
        case calciumMg
        case ironMg
        case vitaminDMcg
        case vitaminCMg
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calories = try container.decodeIfPresent(Int.self, forKey: .calories) ?? 0
        protein = try container.decodeIfPresent(Double.self, forKey: .protein) ?? 0
        carbs = try container.decodeIfPresent(Double.self, forKey: .carbs) ?? 0
        fat = try container.decodeIfPresent(Double.self, forKey: .fat) ?? 0
        fiber = try container.decodeIfPresent(Double.self, forKey: .fiber) ?? 0
        sugars = try container.decodeIfPresent(Double.self, forKey: .sugars) ?? 0
        addedSugars = try container.decodeIfPresent(Double.self, forKey: .addedSugars) ?? 0
        saturatedFat = try container.decodeIfPresent(Double.self, forKey: .saturatedFat) ?? 0
        transFat = try container.decodeIfPresent(Double.self, forKey: .transFat) ?? 0
        cholesterolMg = try container.decodeIfPresent(Double.self, forKey: .cholesterolMg) ?? 0
        sodiumMg = try container.decodeIfPresent(Double.self, forKey: .sodiumMg) ?? 0
        potassiumMg = try container.decodeIfPresent(Double.self, forKey: .potassiumMg) ?? 0
        calciumMg = try container.decodeIfPresent(Double.self, forKey: .calciumMg) ?? 0
        ironMg = try container.decodeIfPresent(Double.self, forKey: .ironMg) ?? 0
        vitaminDMcg = try container.decodeIfPresent(Double.self, forKey: .vitaminDMcg) ?? 0
        vitaminCMg = try container.decodeIfPresent(Double.self, forKey: .vitaminCMg) ?? 0
    }
}

struct NutritionDetailFact: Identifiable, Hashable {
    var id: String
    var label: String
    var value: Double
    var unit: String
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

struct Product: Identifiable, Hashable, Codable, Sendable {
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
    var userEditedAt: Date?
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
        userEditedAt: Date? = nil,
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
        self.userEditedAt = userEditedAt
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
        ingredients.contains { ingredient in
            let normalized = ingredient
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else { return false }
            let placeholders: Set<String> = [
                "undefined",
                "unknown",
                "n/a",
                "na",
                "none",
                "missing"
            ]
            return !placeholders.contains(normalized)
        }
    }

    var hasMeaningfulNutrition: Bool {
        nutrition.calories > 0 || nutrition.protein > 0 || nutrition.carbs > 0 || nutrition.fat > 0 || nutrition.fiber > 0
    }

    var isUserEdited: Bool {
        userEditedAt != nil
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
    var fiber: Double

    init(calories: Int, protein: Double, carbs: Double, fat: Double, fiber: Double = 28) {
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
    }

    static let `default` = MacroGoals(calories: 1800, protein: 120, carbs: 140, fat: 70, fiber: 28)

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

    private enum CodingKeys: String, CodingKey {
        case calories
        case protein
        case carbs
        case fat
        case fiber
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calories = try container.decodeIfPresent(Int.self, forKey: .calories) ?? 1800
        protein = try container.decodeIfPresent(Double.self, forKey: .protein) ?? 120
        carbs = try container.decodeIfPresent(Double.self, forKey: .carbs) ?? 140
        fat = try container.decodeIfPresent(Double.self, forKey: .fat) ?? 70
        fiber = try container.decodeIfPresent(Double.self, forKey: .fiber) ?? 28
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
    var sourceProductID: String?
    var loggedServings: Double?
    var baseServingDescription: String?
    var nutrition: NutritionFacts
    var analysis: ProductAnalysis
    var loggedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        servingText: String,
        sourceProductIDs: [String],
        sourceProductID: String? = nil,
        loggedServings: Double? = nil,
        baseServingDescription: String? = nil,
        nutrition: NutritionFacts,
        analysis: ProductAnalysis,
        loggedAt: Date
    ) {
        self.id = id
        self.title = title
        self.servingText = servingText
        self.sourceProductIDs = sourceProductIDs
        self.sourceProductID = sourceProductID
        self.loggedServings = loggedServings
        self.baseServingDescription = baseServingDescription
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
    var favoriteProductKeys: [String]
    var meals: [SavedMeal]
    var loggedFoods: [LoggedFood]
    var usageCounts: [String: Int]
    var searchCacheByQuery: [String: CachedProductList]
    var barcodeCache: [String: CachedProductValue]
    var deepSearchCache: [String: CachedProductValue]
    var favoriteImportJobs: [FavoriteImportJob]

    init(
        selectedDiet: DietProfile,
        goals: MacroGoals,
        cachedProducts: [Product],
        favoriteProductKeys: [String],
        meals: [SavedMeal],
        loggedFoods: [LoggedFood],
        usageCounts: [String: Int],
        searchCacheByQuery: [String: CachedProductList] = [:],
        barcodeCache: [String: CachedProductValue] = [:],
        deepSearchCache: [String: CachedProductValue] = [:],
        favoriteImportJobs: [FavoriteImportJob] = []
    ) {
        self.selectedDiet = selectedDiet
        self.goals = goals
        self.cachedProducts = cachedProducts
        self.favoriteProductKeys = favoriteProductKeys
        self.meals = meals
        self.loggedFoods = loggedFoods
        self.usageCounts = usageCounts
        self.searchCacheByQuery = searchCacheByQuery
        self.barcodeCache = barcodeCache
        self.deepSearchCache = deepSearchCache
        self.favoriteImportJobs = favoriteImportJobs
    }

    private enum CodingKeys: String, CodingKey {
        case selectedDiet
        case goals
        case cachedProducts
        case favoriteProductKeys
        case meals
        case loggedFoods
        case usageCounts
        case searchCacheByQuery
        case barcodeCache
        case deepSearchCache
        case favoriteImportJobs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedDiet = try container.decodeIfPresent(DietProfile.self, forKey: .selectedDiet) ?? .whole30
        goals = try container.decodeIfPresent(MacroGoals.self, forKey: .goals) ?? .default
        cachedProducts = try container.decodeIfPresent([Product].self, forKey: .cachedProducts) ?? []
        favoriteProductKeys = try container.decodeIfPresent([String].self, forKey: .favoriteProductKeys) ?? []
        meals = try container.decodeIfPresent([SavedMeal].self, forKey: .meals) ?? []
        loggedFoods = try container.decodeIfPresent([LoggedFood].self, forKey: .loggedFoods) ?? []
        usageCounts = try container.decodeIfPresent([String: Int].self, forKey: .usageCounts) ?? [:]
        searchCacheByQuery = try container.decodeIfPresent([String: CachedProductList].self, forKey: .searchCacheByQuery) ?? [:]
        barcodeCache = try container.decodeIfPresent([String: CachedProductValue].self, forKey: .barcodeCache) ?? [:]
        deepSearchCache = try container.decodeIfPresent([String: CachedProductValue].self, forKey: .deepSearchCache) ?? [:]
        favoriteImportJobs = try container.decodeIfPresent([FavoriteImportJob].self, forKey: .favoriteImportJobs) ?? []
    }
}

enum FavoriteImportJobStatus: String, Codable, Hashable {
    case pending
    case running
    case completed
    case failed
}

struct FavoriteImportLineResult: Hashable, Codable {
    var itemName: String
    var success: Bool
    var reason: String
    var canonicalProductKey: String?
}

struct FavoriteImportRunResult: Hashable, Codable {
    var attemptedCount: Int
    var importedCount: Int
    var failedCount: Int
    var importedCanonicalProductKeys: [String]
    var lineResults: [FavoriteImportLineResult]
    var completedAt: Date
}

struct FavoriteImportJob: Identifiable, Hashable, Codable {
    var id: String
    var sourceLabel: String
    var payload: String
    var scheduledAt: Date
    var createdAt: Date
    var status: FavoriteImportJobStatus
    var lastRunAt: Date?
    var lastResult: FavoriteImportRunResult?
    var lastError: String?

    init(
        id: String = UUID().uuidString,
        sourceLabel: String,
        payload: String,
        scheduledAt: Date,
        createdAt: Date = .now,
        status: FavoriteImportJobStatus = .pending,
        lastRunAt: Date? = nil,
        lastResult: FavoriteImportRunResult? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.sourceLabel = sourceLabel
        self.payload = payload
        self.scheduledAt = scheduledAt
        self.createdAt = createdAt
        self.status = status
        self.lastRunAt = lastRunAt
        self.lastResult = lastResult
        self.lastError = lastError
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
