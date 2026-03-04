import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var selectedDiet: DietProfile = .whole30
    @Published var goals: MacroGoals = .default
    @Published var cachedProducts: [Product] = []
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
    @Published var usageCounts: [String: Int] = [:]

    @Published var selectedStoreFilter = "All Stores"
    @Published var onlyShowCompatible = false
    @Published var hideCautionOrIncomplete = false
    @Published var query = ""
    @Published var manualBarcode = ""
    @Published var remoteSearchResults: [Product] = []
    @Published var deepSearchResult: Product?
    @Published var searchError: String?
    @Published var isSearching = false
    @Published var isDeepSearching = false
    @Published var hasSubmittedSearch = false
    @Published var barcodeLookupResult: Product?
    @Published var barcodeLookupError: String?
    @Published var isLookingUpBarcode = false

    private let analyzer = IngredientAnalyzer()
    private let catalogService: ProductCatalogServing
    private let deepSearchService: DeepSearchServing
    private let persistence: AppPersistence
    private var cancellables: Set<AnyCancellable> = []
    private var searchCache: [String: [Product]] = [:]
    private var barcodeCache: [String: Product?] = [:]

    init(
        catalogService: ProductCatalogServing = ProductCatalogService(),
        deepSearchService: DeepSearchServing = DeepSearchService(),
        persistence: AppPersistence = AppPersistence()
    ) {
        self.catalogService = catalogService
        self.deepSearchService = deepSearchService
        self.persistence = persistence

        if let state = persistence.load() {
            selectedDiet = state.selectedDiet
            goals = state.goals
            cachedProducts = state.cachedProducts
            meals = state.meals
            loggedFoods = state.loggedFoods
            usageCounts = state.usageCounts
        }

        setupPersistence()
    }

    var localCatalog: [Product] {
        deduplicatedProductsByID(bestProductsByCanonicalKey(SampleData.products + cachedProducts))
    }

    var mealBuilderProducts: [Product] {
        localCatalog.sorted { combinedRankingScore(for: $0) > combinedRankingScore(for: $1) }
    }

    var availableStores: [String] {
        ["All Stores"] + Array(Set(localCatalog.flatMap(\.stores))).sorted()
    }

    var localProductResults: [Product] {
        let candidates = query.isEmpty ? localCatalog : localCatalog.filter(matchesSearchQuery)
        return candidates
            .filter(matchesFilters)
            .sorted { combinedRankingScore(for: $0) > combinedRankingScore(for: $1) }
    }

    var searchResults: [Product] {
        let combined = deduplicatedProductsByID(localProductResults + remoteSearchResults + (deepSearchResult.map { [$0] } ?? []))
        return combined
            .filter { !$0.isLowConfidenceCatalogEntry || !$0.ingredients.isEmpty }
            .filter(matchesFilters)
            .sorted { combinedRankingScore(for: $0) > combinedRankingScore(for: $1) }
    }

    var matchingMeals: [SavedMeal] {
        guard !query.isEmpty else { return meals }
        let normalized = normalizedTerms(for: query)
        return meals.filter { meal in
            let haystack = "\(meal.name) \(meal.components.map(\.product.name).joined(separator: " "))".lowercased()
            return normalized.allSatisfy(haystack.contains)
        }
    }

    var todayNutrition: NutritionFacts {
        loggedFoods.reduce(.zero) { $0 + $1.nutrition }
    }

    func performSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hasSubmittedSearch = true
        searchError = nil
        deepSearchResult = nil

        guard !trimmed.isEmpty else {
            remoteSearchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            let cacheKey = normalizedSearchKey(for: trimmed)
            let products: [Product]
            if let cached = searchCache[cacheKey] {
                products = cached
            } else {
                products = try await catalogService.searchProducts(matching: trimmed)
                searchCache[cacheKey] = products
            }
            remoteSearchResults = products
            mergeIntoCache(products)
            if shouldDeepSearch(after: products) {
                await runDeepSearch(for: trimmed)
            } else if products.isEmpty, localProductResults.isEmpty, matchingMeals.isEmpty {
                searchError = "No matching foods found in your local library or the online catalog."
            }
        } catch {
            remoteSearchResults = []
            searchError = error.localizedDescription
            await runDeepSearch(for: trimmed)
        }
    }

    func lookupBarcode(_ barcode: String) async {
        let trimmed = BarcodeNormalizer.digitsOnly(from: barcode)
        manualBarcode = trimmed
        barcodeLookupError = nil
        barcodeLookupResult = nil

        guard !trimmed.isEmpty else { return }

        let variants = Set(BarcodeNormalizer.variants(for: trimmed))
        if let local = localCatalog.first(where: { variants.contains(BarcodeNormalizer.digitsOnly(from: $0.barcode)) }) {
            barcodeLookupResult = local
            return
        }

        if let cachedVariant = variants.first(where: { barcodeCache.keys.contains($0) }) {
            let cached = barcodeCache[cachedVariant] ?? nil
            barcodeLookupResult = cached
            if cached == nil {
                barcodeLookupError = "No product found for barcode \(trimmed)."
            }
            return
        }

        isLookingUpBarcode = true
        defer { isLookingUpBarcode = false }

        do {
            let fetched = try await catalogService.product(forBarcode: trimmed)
            for variant in variants {
                barcodeCache[variant] = fetched
            }
            if let fetched {
                mergeIntoCache([fetched])
                barcodeLookupResult = fetched
            } else {
                barcodeLookupError = "No product found for barcode \(trimmed)."
            }
        } catch {
            barcodeLookupError = error.localizedDescription
        }
    }

    func clearSearch() {
        query = ""
        remoteSearchResults = []
        deepSearchResult = nil
        searchError = nil
        hasSubmittedSearch = false
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
        let variants = Set(BarcodeNormalizer.variants(for: barcode))
        return localCatalog.first(where: { variants.contains(BarcodeNormalizer.digitsOnly(from: $0.barcode)) })
    }

    func saveMeal(name: String, selections: [String: Double]) {
        let components = mealBuilderProducts.compactMap { product -> MealComponent? in
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
        usageCounts[product.id, default: 0] += 1
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

        for component in meal.components {
            usageCounts[component.product.id, default: 0] += 1
        }
    }

    private func matchesFilters(_ product: Product) -> Bool {
        let matchesStore = selectedStoreFilter == "All Stores" || product.stores.contains(selectedStoreFilter)
        let rating = analysis(for: product).rating
        let matchesDiet = !onlyShowCompatible || rating != .red
        let matchesConfidence = !hideCautionOrIncomplete || rating == .green
        return matchesStore && matchesDiet && matchesConfidence
    }

    private func matchesSearchQuery(_ product: Product) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let queryTerms = normalizedTerms(for: trimmed)
        let haystack = [
            product.name,
            product.brand,
            product.barcode,
            product.ingredients.joined(separator: " "),
            product.stores.joined(separator: " ")
        ]
        .joined(separator: " ")
        .lowercased()

        return queryTerms.allSatisfy(haystack.contains)
    }

    private func normalizedTerms(for string: String) -> [String] {
        string
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private func combinedRankingScore(for product: Product) -> Int {
        let recentBoost = loggedFoods.contains { $0.sourceProductIDs.contains(product.id) } ? 25 : 0
        let usageBoost = usageCounts[product.id, default: 0] * 5
        let completenessBoost = productQualityScore(for: product)
        let ratingBoost: Int
        switch analysis(for: product).rating {
        case .green: ratingBoost = 20
        case .yellow: ratingBoost = 8
        case .red: ratingBoost = 0
        }

        let queryBoost: Int
        if query.isEmpty {
            queryBoost = 0
        } else {
            let normalizedName = product.name.lowercased()
            let normalizedBrand = product.brand.lowercased()
            let trimmed = query.lowercased()
            if normalizedName == trimmed || normalizedBrand == trimmed {
                queryBoost = 50
            } else if normalizedName.contains(trimmed) || normalizedBrand.contains(trimmed) {
                queryBoost = 35
            } else {
                let hits = normalizedTerms(for: query).reduce(into: 0) { partial, term in
                    if normalizedName.contains(term) { partial += 10 }
                    if normalizedBrand.contains(term) { partial += 6 }
                    if product.ingredients.joined(separator: " ").lowercased().contains(term) { partial += 3 }
                }
                queryBoost = hits
            }
        }

        let sourceBoost: Int
        switch product.source {
        case .seed: sourceBoost = 6
        case .openFoodFacts: sourceBoost = 4
        case .upcItemDB: sourceBoost = 1
        case .usda: sourceBoost = 2
        case .deepSearch: sourceBoost = 3
        }
        let completenessPenalty = product.isLowConfidenceCatalogEntry ? -30 : 0
        return recentBoost + usageBoost + completenessBoost + ratingBoost + queryBoost + sourceBoost + completenessPenalty
    }

    private func deduplicatedProductsByID(_ products: [Product]) -> [Product] {
        var seen: Set<String> = []
        return products.filter { product in
            let inserted = seen.insert(product.id).inserted
            return inserted
        }
    }

    private func mergeIntoCache(_ products: [Product]) {
        guard !products.isEmpty else { return }
        let merged = bestProductsByCanonicalKey(products + cachedProducts)
        cachedProducts = merged.sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

    private func bestProductsByCanonicalKey(_ products: [Product]) -> [Product] {
        var bestByKey: [String: Product] = [:]
        for product in products {
            let key = product.canonicalLookupKey
            guard let existing = bestByKey[key] else {
                bestByKey[key] = product
                continue
            }

            if productQualityScore(for: product) > productQualityScore(for: existing) {
                bestByKey[key] = product
            }
        }
        return Array(bestByKey.values)
    }

    private func normalizedSearchKey(for query: String) -> String {
        normalizedTerms(for: query).joined(separator: " ")
    }

    private func productQualityScore(for product: Product) -> Int {
        product.dataCompletenessScore * 6
    }

    private func shouldDeepSearch(after products: [Product]) -> Bool {
        if products.isEmpty, localProductResults.isEmpty, matchingMeals.isEmpty {
            return true
        }

        let bestScore = products.map(\.dataCompletenessScore).max() ?? 0
        let hasCompleteRemoteResult = products.contains { $0.hasIngredientDetails && $0.hasMeaningfulNutrition }
        return !hasCompleteRemoteResult && bestScore < 7
    }

    private func runDeepSearch(for query: String) async {
        isDeepSearching = true
        defer { isDeepSearching = false }

        do {
            if let enriched = try await deepSearchService.deepSearchProduct(matching: query) {
                deepSearchResult = enriched
                mergeIntoCache([enriched])
                searchError = nil
            } else if remoteSearchResults.isEmpty, localProductResults.isEmpty, matchingMeals.isEmpty {
                searchError = "No matching foods found, including deep search."
            }
        } catch {
            if remoteSearchResults.isEmpty, localProductResults.isEmpty, matchingMeals.isEmpty {
                searchError = "No matching foods found, and deep search failed."
            }
        }
    }

    private func setupPersistence() {
        $selectedDiet
            .sink { [weak self] _ in self?.persistState() }
            .store(in: &cancellables)
        $goals
            .sink { [weak self] _ in self?.persistState() }
            .store(in: &cancellables)
        $cachedProducts
            .sink { [weak self] _ in self?.persistState() }
            .store(in: &cancellables)
        $meals
            .sink { [weak self] _ in self?.persistState() }
            .store(in: &cancellables)
        $loggedFoods
            .sink { [weak self] _ in self?.persistState() }
            .store(in: &cancellables)
        $usageCounts
            .sink { [weak self] _ in self?.persistState() }
            .store(in: &cancellables)
    }

    private func persistState() {
        persistence.save(
            PersistedAppState(
                selectedDiet: selectedDiet,
                goals: goals,
                cachedProducts: cachedProducts,
                meals: meals,
                loggedFoods: loggedFoods,
                usageCounts: usageCounts
            )
        )
    }
}
