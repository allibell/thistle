import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var selectedDiet: DietProfile = .whole30
    @Published var goals: MacroGoals = .default
    @Published var products: [Product] = SampleData.products
    @Published var meals: [SavedMeal] = [
        SavedMeal(
            name: "Post-Workout Plate",
            components: [
                MealComponent(product: SampleData.products[0], servings: 2),
                MealComponent(product: SampleData.products[4], servings: 1)
            ]
        )
    ]
    @Published var loggedFoods: [LoggedFood] = []
    @Published var selectedStoreFilter: String = "All Stores"
    @Published var onlyShowCompatible = false
    @Published var query = ""
    @Published var manualBarcode = ""

    private let analyzer = IngredientAnalyzer()

    var availableStores: [String] {
        ["All Stores"] + Array(Set(products.flatMap(\.stores))).sorted()
    }

    var searchResults: [Product] {
        products.filter { product in
            let matchesQuery = query.isEmpty
                || product.name.localizedCaseInsensitiveContains(query)
                || product.brand.localizedCaseInsensitiveContains(query)
                || product.ingredients.joined(separator: ", ").localizedCaseInsensitiveContains(query)
            let matchesStore = selectedStoreFilter == "All Stores" || product.stores.contains(selectedStoreFilter)
            let matchesDiet = !onlyShowCompatible || analysis(for: product).rating != .red
            return matchesQuery && matchesStore && matchesDiet
        }
        .sorted { lhs, rhs in
            let leftScore = rankingScore(for: lhs)
            let rightScore = rankingScore(for: rhs)
            if leftScore == rightScore {
                return lhs.name < rhs.name
            }
            return leftScore > rightScore
        }
    }

    var todayNutrition: NutritionFacts {
        loggedFoods.reduce(.zero) { $0 + $1.nutrition }
    }

    func analysis(for product: Product) -> ProductAnalysis {
        analyzer.analyze(product: product, for: selectedDiet)
    }

    func analysis(for meal: SavedMeal) -> ProductAnalysis {
        let allFlags = meal.components.flatMap { analysis(for: $0.product).flags }
        let rating: ComplianceRating
        if allFlags.contains(where: { $0.severity == .avoid }) {
            rating = .red
        } else if allFlags.contains(where: { $0.severity == .caution }) {
            rating = .yellow
        } else {
            rating = .green
        }
        let summary = "\(meal.components.count) items combined for a \(rating.title.lowercased()) meal."
        return ProductAnalysis(rating: rating, summary: summary, flags: allFlags)
    }

    func productForBarcode(_ barcode: String) -> Product? {
        products.first(where: { $0.barcode == barcode })
    }

    func saveMeal(name: String, selections: [UUID: Double]) {
        let components = products.compactMap { product -> MealComponent? in
            guard let servings = selections[product.id], servings > 0 else { return nil }
            return MealComponent(product: product, servings: servings)
        }
        guard !components.isEmpty else { return }
        meals.insert(SavedMeal(name: name, components: components), at: 0)
    }

    func log(product: Product, servings: Double = 1) {
        let nutrition = product.nutrition * servings
        loggedFoods.insert(
            LoggedFood(
                title: product.name,
                servingText: servings == 1 ? product.servingDescription : "\(servings.formatted()) x \(product.servingDescription)",
                sourceProductIDs: [product.id],
                nutrition: nutrition,
                analysis: analysis(for: product),
                loggedAt: .now
            ),
            at: 0
        )
    }

    func log(meal: SavedMeal) {
        loggedFoods.insert(
            LoggedFood(
                title: meal.name,
                servingText: "Custom meal",
                sourceProductIDs: meal.components.map(\.product.id),
                nutrition: meal.nutrition,
                analysis: analysis(for: meal),
                loggedAt: .now
            ),
            at: 0
        )
    }

    private func rankingScore(for product: Product) -> Int {
        let recentBoost = loggedFoods.contains { $0.sourceProductIDs.contains(product.id) } ? 20 : 0
        let ratingBoost: Int
        switch analysis(for: product).rating {
        case .green: ratingBoost = 10
        case .yellow: ratingBoost = 4
        case .red: ratingBoost = 0
        }
        return recentBoost + ratingBoost
    }
}
