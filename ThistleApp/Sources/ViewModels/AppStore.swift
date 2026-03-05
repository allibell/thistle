import Combine
import Foundation

enum AppTab: Hashable {
    case search
    case scan
    case diary
    case meals
    case goals
}

@MainActor
final class AppStore: ObservableObject {
    struct NutritionInferenceEstimate {
        var nutrition: NutritionFacts
        var servingDescription: String
        var ingredients: [String]
        var sourceSummary: String
    }

    @Published var selectedTab: AppTab = .search
    @Published var selectedDiet: DietProfile = .whole30
    @Published var goals: MacroGoals = .default
    @Published var cachedProducts: [Product] = [] {
        didSet {
            rebuildLocalCatalogSnapshot()
            clearAnalysisCache()
        }
    }
    @Published var favoriteProductKeys: Set<String> = []
    @Published var meals: [SavedMeal] = [
        SavedMeal(
            name: "Post-Workout Plate",
            components: [
                MealComponent(product: SampleData.products[0], servings: 2),
                MealComponent(product: SampleData.products[4], servings: 1)
            ]
        )
    ]
    @Published var loggedFoods: [LoggedFood] = [] {
        didSet {
            rebuildRecentLoggedProductIDs()
        }
    }
    @Published var usageCounts: [String: Int] = [:]
    @Published var favoriteImportJobs: [FavoriteImportJob] = []

    @Published var selectedStoreFilter = "All Stores"
    @Published var onlyShowCompatible = false
    @Published var hideCautionOrIncomplete = false
    @Published var query = ""
    @Published private(set) var activeSearchQuery = ""
    @Published var manualBarcode = ""
    @Published var remoteSearchResults: [Product] = []
    @Published var deepSearchResult: Product?
    @Published var searchError: String?
    @Published var isSearching = false
    @Published var isDeepSearching = false
    @Published var deepSearchDebugLog: [String] = []
    @Published var activeDeepSearchProductID: String?
    @Published var activeDeepSearchScope: DeepSearchScope?
    @Published var pendingDeepSearchProposal: DeepSearchProposal?
    @Published var hasSubmittedSearch = false
    @Published var barcodeLookupResult: Product?
    @Published var barcodeLookupError: String?
    @Published var isLookingUpBarcode = false
    @Published private(set) var localCatalogSnapshot: [Product] = []

    private let analyzer = IngredientAnalyzer()
    private let catalogService: ProductCatalogServing
    private let deepSearchService: DeepSearchServing
    private let persistence: AppPersistence
    private let catalogCacheTTL: TimeInterval = 60 * 60 * 24 * 7
    private let deepSearchCacheTTL: TimeInterval = 60 * 60 * 24
    private let maxWholeFoodsOrderItemsPerRun = 50
    private let maxCachedProducts = 350
    private let maxSearchResults = 60
    private let maxFavoriteProducts = 24
    private let calendar = Calendar.current
    private var cancellables: Set<AnyCancellable> = []
    private var searchCache: [String: CachedProductList] = [:]
    private var barcodeCache: [String: CachedProductValue] = [:]
    private var deepSearchCache: [String: CachedProductValue] = [:]
    private var didStartFiberBackfill = false
    private var analysisCache: [String: ProductAnalysis] = [:]
    private var recentLoggedProductIDs: Set<String> = []

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
            favoriteProductKeys = Set(state.favoriteProductKeys)
            meals = state.meals
            loggedFoods = state.loggedFoods
            usageCounts = state.usageCounts
            searchCache = state.searchCacheByQuery
            barcodeCache = state.barcodeCache
            deepSearchCache = state.deepSearchCache
            favoriteImportJobs = state.favoriteImportJobs
        }
        rebuildRecentLoggedProductIDs()
        pruneExpiredCaches()
        trimCachedProductsIfNeeded()
        rebuildLocalCatalogSnapshot()
        persistState()

        setupPersistence()
        startFiberBackfillIfNeeded()
        Task { [weak self] in
            await self?.runDueFavoriteImportJobs()
        }
    }

    var localCatalog: [Product] {
        localCatalogSnapshot
    }

    var mealBuilderProducts: [Product] {
        rankedProducts(localCatalog)
    }

    var favoriteProducts: [Product] {
        rankedProducts(localCatalog.filter(isFavorite), limit: maxFavoriteProducts)
    }

    var availableStores: [String] {
        let candidates = localCatalog
            + remoteSearchResults
            + (deepSearchResult.map { [$0] } ?? [])
        return ["All Stores"] + Array(Set(candidates.flatMap(\.stores))).sorted()
    }

    var localProductResults: [Product] {
        guard !activeSearchQuery.isEmpty else { return [] }
        let candidates = localCatalog.filter(matchesSearchQuery)
        return rankedProducts(
            candidates.filter(matchesFilters),
            limit: maxSearchResults
        )
    }

    var recentHistoryProducts: [Product] {
        let catalogByID = Dictionary(uniqueKeysWithValues: localCatalog.map { ($0.id, $0) })
        var ordered: [Product] = []
        var seen: Set<String> = []

        for entry in loggedFoods {
            for productID in entry.sourceProductIDs {
                guard seen.insert(productID).inserted, let product = catalogByID[productID] else { continue }
                ordered.append(product)
                if ordered.count >= 8 { return ordered }
            }
        }

        if ordered.count < 8 {
            let fallbackIDs = usageCounts
                .filter { $0.value > 0 && !seen.contains($0.key) }
                .sorted {
                    if $0.value == $1.value { return $0.key < $1.key }
                    return $0.value > $1.value
                }
                .map(\.key)

            for productID in fallbackIDs {
                guard let product = catalogByID[productID] else { continue }
                ordered.append(product)
                if ordered.count >= 8 { break }
            }
        }

        return ordered
    }

    var searchResults: [Product] {
        guard !activeSearchQuery.isEmpty else { return [] }
        let combined = deduplicatedProductsByID(localProductResults + remoteSearchResults + (deepSearchResult.map { [$0] } ?? []))
        return rankedProducts(
            combined
            .filter(matchesSearchQuery)
            .filter(shouldSurfaceSearchResult)
            .filter(matchesFilters),
            limit: maxSearchResults
        )
    }

    private func rankedProducts(_ products: [Product], limit: Int? = nil) -> [Product] {
        let ranked = products
            .map { (product: $0, score: combinedRankingScore(for: $0)) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.product.lastUpdatedAt > rhs.product.lastUpdatedAt
                }
                return lhs.score > rhs.score
            }
            .map(\.product)
        if let limit {
            return Array(ranked.prefix(limit))
        }
        return ranked
    }

    private func shouldSurfaceSearchResult(_ product: Product) -> Bool {
        if !product.isLowConfidenceCatalogEntry || !product.ingredients.isEmpty {
            return true
        }

        let trimmedQuery = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return false
        }

        let normalizedQuery = trimmedQuery.lowercased()
        let identity = "\(product.brand) \(product.name)".lowercased()
        if identity.contains(normalizedQuery) {
            return true
        }

        let queryTerms = Set(normalizedTerms(for: trimmedQuery))
        guard !queryTerms.isEmpty else {
            return false
        }

        let identityTerms = Set(normalizedTerms(for: identity))
        let overlap = queryTerms.intersection(identityTerms).count

        if overlap == queryTerms.count {
            return true
        }

        if queryTerms.count >= 2,
           overlap >= queryTerms.count - 1,
           product.hasMeaningfulNutrition || !product.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        return false
    }

    var matchingMeals: [SavedMeal] {
        guard !activeSearchQuery.isEmpty else { return meals }
        let normalized = normalizedTerms(for: activeSearchQuery)
        return meals.filter { meal in
            let haystack = "\(meal.name) \(meal.components.map(\.product.name).joined(separator: " "))".lowercased()
            return normalized.allSatisfy(haystack.contains)
        }
    }

    var todayNutrition: NutritionFacts {
        nutrition(on: .now)
    }

    func loggedFoods(on date: Date) -> [LoggedFood] {
        loggedFoods.filter { calendar.isDate($0.loggedAt, inSameDayAs: date) }
    }

    func nutrition(on date: Date) -> NutritionFacts {
        loggedFoods(on: date).reduce(.zero) { $0 + $1.nutrition }
    }

    func performSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchQuery = trimmed
        hasSubmittedSearch = true
        searchError = nil
        deepSearchResult = nil
        remoteSearchResults = []

        guard !trimmed.isEmpty else {
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            let cacheKey = normalizedSearchKey(for: trimmed)
            if let cached = searchCache[cacheKey], isFresh(cached.cachedAt, ttl: catalogCacheTTL) {
                let normalizedCachedProducts = cached.products.map(withInferredStores)
                remoteSearchResults = normalizedCachedProducts
                mergeIntoCache(Array(normalizedCachedProducts.prefix(24)))
                if cached.products.isEmpty, localProductResults.isEmpty, matchingMeals.isEmpty {
                    searchError = "No matching foods found in your local library or the online catalog."
                }
                return
            }

            if let stale = searchCache[cacheKey], !stale.products.isEmpty {
                // Show stale results immediately, then refresh from network.
                let normalizedStaleProducts = stale.products.map(withInferredStores)
                remoteSearchResults = normalizedStaleProducts
                mergeIntoCache(Array(normalizedStaleProducts.prefix(24)))
            }

            let products = try await catalogService.searchProducts(matching: trimmed)
            let normalizedProducts = products.map(withInferredStores)
            if !products.isEmpty {
                searchCache[cacheKey] = CachedProductList(products: normalizedProducts, cachedAt: .now)
                persistState()
            } else {
                searchCache[cacheKey] = nil
            }

            remoteSearchResults = normalizedProducts
            mergeIntoCache(Array(normalizedProducts.prefix(24)))
            if products.isEmpty, localProductResults.isEmpty, matchingMeals.isEmpty {
                searchError = "No matching foods found in your local library or the online catalog."
            }
        } catch {
            if remoteSearchResults.isEmpty {
                searchError = error.localizedDescription
            } else {
                searchError = "Showing cached results. Live catalog refresh failed."
            }
        }
    }

    func runManualDeepSearchForCurrentQuery() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeSearchQuery = trimmed
        await runDeepSearch(for: trimmed)
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

        if let cachedVariant = variants.first(where: { barcodeCache.keys.contains($0) }),
           let cached = barcodeCache[cachedVariant] {
            if isFresh(cached.cachedAt, ttl: catalogCacheTTL) {
                barcodeLookupResult = cached.product.map(withInferredStores)
                if cached.product == nil {
                    barcodeLookupError = "No product found for barcode \(trimmed)."
                }
                return
            }
            barcodeCache[cachedVariant] = nil
            persistState()
        }

        isLookingUpBarcode = true
        defer { isLookingUpBarcode = false }

        do {
            let fetched = try await catalogService.product(forBarcode: trimmed)
            let normalizedFetched = fetched.map(withInferredStores)
            for variant in variants {
                barcodeCache[variant] = CachedProductValue(product: normalizedFetched, cachedAt: .now)
            }
            persistState()
            if let normalizedFetched {
                mergeIntoCache([normalizedFetched])
                barcodeLookupResult = normalizedFetched
            } else {
                barcodeLookupError = "No product found for barcode \(trimmed)."
            }
        } catch {
            barcodeLookupError = error.localizedDescription
        }
    }

    func resetBarcodeLookupState(clearManualBarcode: Bool = false) {
        barcodeLookupResult = nil
        barcodeLookupError = nil
        isLookingUpBarcode = false
        if clearManualBarcode {
            manualBarcode = ""
        }
    }

    func clearSearch() {
        if query.isEmpty,
           activeSearchQuery.isEmpty,
           remoteSearchResults.isEmpty,
           deepSearchResult == nil,
           searchError == nil,
           !hasSubmittedSearch {
            return
        }
        query = ""
        activeSearchQuery = ""
        remoteSearchResults = []
        deepSearchResult = nil
        searchError = nil
        hasSubmittedSearch = false
    }

    func analysis(for product: Product) -> ProductAnalysis {
        let key = analysisCacheKey(for: product)
        if let cached = analysisCache[key] {
            return cached
        }
        let computed = analyzer.analyze(product: product, for: selectedDiet)
        analysisCache[key] = computed
        return computed
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

    func product(withID id: String) -> Product? {
        localCatalog.first(where: { $0.id == id })
    }

    func isFavorite(_ product: Product) -> Bool {
        favoriteProductKeys.contains(product.canonicalLookupKey)
    }

    func toggleFavorite(_ product: Product) {
        if !localCatalog.contains(where: { $0.id == product.id }) {
            mergeIntoCache([product])
        }
        let key = product.canonicalLookupKey
        if favoriteProductKeys.contains(key) {
            favoriteProductKeys.remove(key)
        } else {
            favoriteProductKeys.insert(key)
        }
    }

    func resolvedProduct(for product: Product) -> Product {
        if let exact = localCatalog.first(where: { $0.id == product.id }) {
            return exact
        }

        let canonicalMatches = localCatalog.filter { $0.canonicalLookupKey == product.canonicalLookupKey }
        if let canonicalBest = canonicalMatches.max(by: preferredProductOrder(lhs:rhs:)) {
            return canonicalBest
        }

        let variants = Set(BarcodeNormalizer.variants(for: product.barcode))
        if !variants.isEmpty,
           let barcodeBest = localCatalog
            .filter({ variants.contains(BarcodeNormalizer.digitsOnly(from: $0.barcode)) })
            .max(by: preferredProductOrder(lhs:rhs:)) {
            return barcodeBest
        }

        return product
    }

    func enrich(product: Product, scope: DeepSearchScope) async {
        resetDeepSearchDebugLog()
        pendingDeepSearchProposal = nil
        let cacheKey = deepSearchProductCacheKey(for: product, scope: scope)
        if let cached = deepSearchCache[cacheKey], isFresh(cached.cachedAt, ttl: deepSearchCacheTTL) {
            appendDeepSearchLog("Using cached deep search candidate for \(product.name) [scope: \(scope.rawValue)].")
            if let cachedCandidate = cached.product {
                guard let proposal = buildDeepSearchProposal(for: product, candidate: cachedCandidate, scope: scope) else {
                    appendDeepSearchLog("Cached candidate was rejected by quality checks. Continuing with live deep search.")
                    deepSearchCache[cacheKey] = nil
                    persistState()
                    return await runLiveDeepSearchEnrichment(for: product, scope: scope, cacheKey: cacheKey)
                }
                pendingDeepSearchProposal = proposal
                appendDeepSearchLog("Prepared a pending update with \(proposal.changedFields.count) field change(s).")
                appendDeepSearchLog("Waiting for manual approval before applying.")
                return
            } else {
                appendDeepSearchLog("Cached deep search miss for this product and scope. Continuing with live deep search.")
                deepSearchCache[cacheKey] = nil
                persistState()
                return await runLiveDeepSearchEnrichment(for: product, scope: scope, cacheKey: cacheKey)
            }
        }

        await runLiveDeepSearchEnrichment(for: product, scope: scope, cacheKey: cacheKey)
    }

    private func runLiveDeepSearchEnrichment(for product: Product, scope: DeepSearchScope, cacheKey: String) async {
        isDeepSearching = true
        activeDeepSearchProductID = product.id
        activeDeepSearchScope = scope
        appendDeepSearchLog("Starting deep search update for \(product.name) [scope: \(scope.rawValue)].")
        defer { isDeepSearching = false }
        defer {
            activeDeepSearchProductID = nil
            activeDeepSearchScope = nil
        }

        do {
            appendDeepSearchLog("Querying fallback sources.")
            if !product.hasIngredientDetails, scope == .all || scope == .ingredients {
                appendDeepSearchLog("Missing ingredients detected: deep search will run an additional slow OCR image pass.")
            }
            guard let enriched = try await deepSearchService.deepSearchProduct(for: product, scope: scope) else {
                deepSearchCache[cacheKey] = CachedProductValue(product: nil, cachedAt: .now)
                persistState()
                appendDeepSearchLog("Deep search found no candidate.")
                return
            }
            deepSearchCache[cacheKey] = CachedProductValue(product: enriched, cachedAt: .now)
            persistState()
            appendDeepSearchLog("Deep search found a candidate: \(enriched.name).")
            if !enriched.hasIngredientDetails, !product.hasIngredientDetails, scope == .all || scope == .ingredients {
                appendDeepSearchLog("OCR fallback completed but still could not extract ingredient text from candidate sources.")
                appendDeepSearchLog("Final AI fallback is wired but currently disabled until API keys/provider are configured.")
            }
            guard let proposal = buildDeepSearchProposal(for: product, candidate: enriched, scope: scope) else {
                appendDeepSearchLog("Rejected candidate because it did not look like a confident match or did not add useful missing data.")
                return
            }

            pendingDeepSearchProposal = proposal
            appendDeepSearchLog("Prepared a pending update with \(proposal.changedFields.count) field change(s).")
            appendDeepSearchLog("Waiting for manual approval before applying.")
        } catch {
            searchError = "Deep search update failed."
            appendDeepSearchLog("Deep search failed: \(error.localizedDescription)")
        }
    }

    func approvePendingDeepSearchProposal() {
        guard let proposal = pendingDeepSearchProposal else { return }

        mergeIntoCache([proposal.mergedProduct])
        if deepSearchResult?.id == proposal.productID {
            deepSearchResult = proposal.mergedProduct
        }
        if barcodeLookupResult?.id == proposal.productID {
            barcodeLookupResult = proposal.mergedProduct
        }
        appendDeepSearchLog("Applied approved update to the local cache.")
        pendingDeepSearchProposal = nil
    }

    func rejectPendingDeepSearchProposal() {
        guard pendingDeepSearchProposal != nil else { return }
        appendDeepSearchLog("Rejected pending update.")
        pendingDeepSearchProposal = nil
    }

    func isDeepSearchActive(productID: String, scope: DeepSearchScope? = nil) -> Bool {
        guard isDeepSearching, activeDeepSearchProductID == productID else { return false }
        guard let scope else { return true }
        return activeDeepSearchScope == scope
    }

    func setMacroPercents(protein: Int, carbs: Int, fat: Int) {
        goals.setMacroPercents(protein: protein, carbs: carbs, fat: fat)
    }

    func saveMeal(name: String, selections: [String: Double], availableProducts: [Product]? = nil) {
        let productPool = deduplicatedProductsByID((availableProducts ?? mealBuilderProducts) + mealBuilderProducts)
        let components = productPool.compactMap { product -> MealComponent? in
            guard let servings = selections[product.id], servings > 0 else { return nil }
            return MealComponent(product: product, servings: servings)
        }
        guard !components.isEmpty else { return }
        meals.insert(
            SavedMeal(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom Meal" : name,
                components: components
            ),
            at: 0
        )
    }

    func updateMeal(mealID: String, name: String, selections: [String: Double], availableProducts: [Product]? = nil) {
        guard let index = meals.firstIndex(where: { $0.id == mealID }) else { return }
        let productPool = deduplicatedProductsByID((availableProducts ?? mealBuilderProducts) + mealBuilderProducts)
        let components = productPool.compactMap { product -> MealComponent? in
            guard let servings = selections[product.id], servings > 0 else { return nil }
            return MealComponent(product: product, servings: servings)
        }
        guard !components.isEmpty else { return }
        meals[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom Meal" : name
        meals[index].components = components
    }

    @discardableResult
    func createMeal(name: String, with product: Product, servings: Double = 1) -> SavedMeal? {
        guard servings > 0 else { return nil }
        mergeIntoCache([product])
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "\(product.name) Meal" : trimmedName
        let meal = SavedMeal(
            name: resolvedName,
            components: [MealComponent(product: product, servings: servings)]
        )
        meals.insert(meal, at: 0)
        return meal
    }

    func addProduct(_ product: Product, servings: Double = 1, toMealID mealID: String) {
        guard servings > 0 else { return }
        guard let index = meals.firstIndex(where: { $0.id == mealID }) else { return }
        mergeIntoCache([product])

        if let componentIndex = meals[index].components.firstIndex(where: { $0.product.id == product.id }) {
            meals[index].components[componentIndex].servings += servings
        } else {
            meals[index].components.append(MealComponent(product: product, servings: servings))
        }
    }

    func deleteMeal(mealID: String) {
        meals.removeAll { $0.id == mealID }
    }

    @discardableResult
    func saveManualProduct(
        existingProductID: String? = nil,
        name: String,
        brand: String,
        barcode: String,
        servingDescription: String,
        ingredientsText: String,
        calories: Int,
        protein: Double,
        carbs: Double,
        fat: Double,
        fiber: Double,
        storesText: String,
        imageURLText: String
    ) -> Product {
        let existing = existingProductID.flatMap { id in
            product(withID: id)
                ?? cachedProducts.first(where: { $0.id == id })
                ?? localCatalog.first(where: { $0.id == id })
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedServing = servingDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        let ingredients = parseDelimitedValues(ingredientsText)
        let stores = parseDelimitedValues(storesText)
        let imageURL = URL(string: imageURLText.trimmingCharacters(in: .whitespacesAndNewlines))

        let manualProduct = Product(
            id: existing?.id,
            source: existing?.source ?? .manual,
            name: trimmedName.isEmpty ? "Custom Product" : trimmedName,
            brand: trimmedBrand.isEmpty ? "Unknown Brand" : trimmedBrand,
            barcode: BarcodeNormalizer.digitsOnly(from: barcode),
            stores: stores,
            servingDescription: trimmedServing.isEmpty ? "1 serving" : trimmedServing,
            ingredients: ingredients,
            nutrition: NutritionFacts(
                calories: max(0, calories),
                protein: max(0, protein),
                carbs: max(0, carbs),
                fat: max(0, fat),
                fiber: max(0, fiber)
            ),
            imageURL: imageURL,
            userEditedAt: .now,
            lastUpdatedAt: .now
        )

        mergeIntoCache([manualProduct])
        if let currentDeepSearchResult = deepSearchResult,
           isSameProductIdentity(lhs: currentDeepSearchResult, rhs: manualProduct) {
            deepSearchResult = manualProduct
        }
        if let currentBarcodeLookupResult = barcodeLookupResult,
           isSameProductIdentity(lhs: currentBarcodeLookupResult, rhs: manualProduct) {
            barcodeLookupResult = manualProduct
        }
        return manualProduct
    }

    func inferNutritionEstimate(title: String, ingredientsText: String) async -> NutritionInferenceEstimate? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedIngredients = parseDelimitedValues(ingredientsText)
        let query = nutritionInferenceQuery(title: trimmedTitle, ingredients: parsedIngredients)
        guard !query.isEmpty else { return nil }

        if let deepSearchMatch = try? await deepSearchService.deepSearchProduct(matching: query),
           deepSearchMatch.hasMeaningfulNutrition {
            return NutritionInferenceEstimate(
                nutrition: deepSearchMatch.nutrition,
                servingDescription: deepSearchMatch.servingDescription,
                ingredients: deepSearchMatch.ingredients.isEmpty ? parsedIngredients : deepSearchMatch.ingredients,
                sourceSummary: "Estimated from online nutrition sources."
            )
        }

        if let localMatch = localNutritionInferenceCandidate(title: trimmedTitle, ingredients: parsedIngredients) {
            return NutritionInferenceEstimate(
                nutrition: localMatch.nutrition,
                servingDescription: localMatch.servingDescription,
                ingredients: localMatch.ingredients.isEmpty ? parsedIngredients : localMatch.ingredients,
                sourceSummary: "Estimated from a similar food already in your local catalog."
            )
        }

        if let heuristicEstimate = heuristicNutritionEstimate(for: query) {
            return heuristicEstimate
        }

        return nil
    }

    @discardableResult
    func addProductFromLink(_ link: String, fallbackQuery: String? = nil) async throws -> Product? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw CatalogError.invalidQuery
        }

        if let linked = try await deepSearchService.deepSearchProduct(from: url) {
            mergeIntoCache([linked])
            return linked
        }

        if let fallbackQuery, let fallback = try await deepSearchService.deepSearchProduct(matching: fallbackQuery) {
            mergeIntoCache([fallback])
            return fallback
        }

        return nil
    }

    @discardableResult
    func enqueueWholeFoodsOrderImport(_ orderText: String, scheduledAt: Date = .now) -> FavoriteImportJob? {
        let trimmed = orderText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let job = FavoriteImportJob(
            sourceLabel: "whole-foods-order",
            payload: trimmed,
            scheduledAt: scheduledAt,
            status: .pending
        )
        favoriteImportJobs.insert(job, at: 0)
        return job
    }

    @discardableResult
    func importWholeFoodsOrderToFavorites(_ orderText: String) async -> FavoriteImportRunResult {
        await importWholeFoodsOrderFavorites(payload: orderText)
    }

    func runDueFavoriteImportJobs() async {
        guard !favoriteImportJobs.isEmpty else { return }
        let now = Date.now
        let dueJobIDs = favoriteImportJobs
            .filter { $0.status == .pending && $0.scheduledAt <= now }
            .map(\.id)

        for jobID in dueJobIDs {
            guard let index = favoriteImportJobs.firstIndex(where: { $0.id == jobID }) else { continue }
            favoriteImportJobs[index].status = .running
            favoriteImportJobs[index].lastRunAt = .now
            favoriteImportJobs[index].lastError = nil

            let payload = favoriteImportJobs[index].payload
            let result = await importWholeFoodsOrderFavorites(payload: payload)
            favoriteImportJobs[index].lastResult = result
            favoriteImportJobs[index].status = result.failedCount == result.attemptedCount ? .failed : .completed
            if result.failedCount == result.attemptedCount {
                favoriteImportJobs[index].lastError = "No order lines could be imported."
            }
        }
    }

    func log(product: Product, servings: Double = 1) {
        let nutrition = product.nutrition * servings
        let roundedBaseServing = roundedNumericText(in: product.servingDescription)
        let roundedServingText = servings == 1
            ? roundedBaseServing
            : "\(servings.formatted(.number.precision(.fractionLength(0...2)))) x \(roundedBaseServing)"
        loggedFoods.insert(
            LoggedFood(
                title: product.name,
                servingText: roundedServingText,
                sourceProductIDs: [product.id],
                sourceProductID: product.id,
                loggedServings: servings,
                baseServingDescription: roundedBaseServing,
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
                servingText: "1 x meal serving",
                sourceProductIDs: meal.components.map(\.product.id),
                sourceProductID: nil,
                loggedServings: 1,
                baseServingDescription: "meal serving",
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

    private func importWholeFoodsOrderFavorites(payload: String) async -> FavoriteImportRunResult {
        let parsedItems = parseWholeFoodsOrderItems(from: payload, maxItems: maxWholeFoodsOrderItemsPerRun)
        guard !parsedItems.isEmpty else {
            return FavoriteImportRunResult(
                attemptedCount: 0,
                importedCount: 0,
                failedCount: 0,
                importedCanonicalProductKeys: [],
                lineResults: [],
                completedAt: .now
            )
        }

        var lineResults: [FavoriteImportLineResult] = []
        var importedKeys: [String] = []

        for item in parsedItems {
            if Task.isCancelled { break }
            guard let resolved = await resolveWholeFoodsProduct(for: item.name) else {
                lineResults.append(
                    FavoriteImportLineResult(
                        itemName: item.name,
                        success: false,
                        reason: "No matching product found from catalog/deep search.",
                        canonicalProductKey: nil
                    )
                )
                continue
            }

            mergeIntoCache([resolved])
            let key = resolved.canonicalLookupKey
            favoriteProductKeys.insert(key)
            importedKeys.append(key)

            lineResults.append(
                FavoriteImportLineResult(
                    itemName: item.name,
                    success: true,
                    reason: "Imported and added to favorites.",
                    canonicalProductKey: key
                )
            )
        }

        let importedSet = Array(Set(importedKeys)).sorted()
        let importedCount = lineResults.filter(\.success).count
        let attemptedCount = lineResults.count
        return FavoriteImportRunResult(
            attemptedCount: attemptedCount,
            importedCount: importedCount,
            failedCount: max(0, attemptedCount - importedCount),
            importedCanonicalProductKeys: importedSet,
            lineResults: lineResults,
            completedAt: .now
        )
    }

    func deleteLoggedFood(entryID: String) {
        loggedFoods.removeAll { $0.id == entryID }
    }

    func updateLoggedFoodServing(entryID: String, servings: Double) {
        guard let index = loggedFoods.firstIndex(where: { $0.id == entryID }) else { return }
        guard servings > 0 else { return }

        var entry = loggedFoods[index]
        if entry.sourceProductID == nil, entry.sourceProductIDs.count > 1 {
            let previousServings = max(entry.loggedServings ?? 1, 0.1)
            let scaleFactor = servings / previousServings
            entry.loggedServings = servings
            entry.baseServingDescription = entry.baseServingDescription ?? "meal serving"
            let roundedAmount = servings.formatted(.number.precision(.fractionLength(0...2)))
            entry.servingText = "\(roundedAmount) x \(entry.baseServingDescription ?? "meal serving")"
            entry.nutrition = entry.nutrition * scaleFactor
            loggedFoods[index] = entry
            return
        }
        let effectiveProductID = entry.sourceProductID ?? entry.sourceProductIDs.first
        if let effectiveProductID,
           let product = product(withID: effectiveProductID) {
            entry.loggedServings = servings
            let roundedBaseServing = roundedNumericText(in: product.servingDescription)
            entry.baseServingDescription = roundedBaseServing
            entry.servingText = servings == 1
                ? roundedBaseServing
                : "\(servings.formatted(.number.precision(.fractionLength(0...2)))) x \(roundedBaseServing)"
            entry.nutrition = product.nutrition * servings
            entry.analysis = analysis(for: product)
            loggedFoods[index] = entry
            return
        }

        if let previousServings = entry.loggedServings, previousServings > 0 {
            let multiplier = servings / previousServings
            entry.nutrition = entry.nutrition * multiplier
            let baseDescription = roundedNumericText(in: entry.baseServingDescription ?? entry.servingText)
            entry.baseServingDescription = baseDescription
            entry.servingText = servings == 1
                ? baseDescription
                : "\(servings.formatted(.number.precision(.fractionLength(0...2)))) x \(baseDescription)"
            entry.loggedServings = servings
            loggedFoods[index] = entry
        }
    }

    private func matchesFilters(_ product: Product) -> Bool {
        let matchesStore = storeFilterMatches(product: product)
        let rating = analysis(for: product).rating
        let matchesDiet = !onlyShowCompatible || rating != .red
        let matchesConfidence = !hideCautionOrIncomplete || rating == .green
        return matchesStore && matchesDiet && matchesConfidence
    }

    private func storeFilterMatches(product: Product) -> Bool {
        guard selectedStoreFilter != "All Stores" else { return true }

        let selectedNorm = normalizeStoreName(selectedStoreFilter)
        guard !selectedNorm.isEmpty else { return true }

        let candidateStores = product.stores.map(normalizeStoreName).filter { !$0.isEmpty }
        if candidateStores.isEmpty {
            // Store metadata is often missing from catalog APIs; avoid empty-result dead ends.
            return true
        }

        if candidateStores.contains(where: { $0 == selectedNorm || $0.contains(selectedNorm) || selectedNorm.contains($0) }) {
            return true
        }

        let aliases = storeAliases(for: selectedNorm)
        return candidateStores.contains { candidate in
            aliases.contains(where: { alias in
                candidate == alias || candidate.contains(alias) || alias.contains(candidate)
            })
        }
    }

    private func normalizeStoreName(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDelimitedValues(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func nutritionInferenceQuery(title: String, ingredients: [String]) -> String {
        var components: [String] = []
        if !title.isEmpty {
            components.append(title)
        }
        if !ingredients.isEmpty {
            components.append("ingredients \(ingredients.prefix(8).joined(separator: ", "))")
        }
        if components.isEmpty {
            return ""
        }
        components.append("nutrition facts")
        return components.joined(separator: " ")
    }

    private func localNutritionInferenceCandidate(title: String, ingredients: [String]) -> Product? {
        let normalizedTitle = normalizedComparableText(title)
        let titleTerms = Set(normalizedTerms(for: title))
        let ingredientTerms = Set(ingredients.flatMap { normalizedTerms(for: $0) })
        let combinedTerms = titleTerms.union(ingredientTerms)
        guard !combinedTerms.isEmpty else { return nil }

        let rankedCandidates = localCatalog
            .filter(\.hasMeaningfulNutrition)
            .compactMap { product -> (product: Product, score: Int)? in
                let identityTerms = Set(normalizedTerms(for: "\(product.brand) \(product.name)"))
                let productIngredientTerms = Set(normalizedTerms(for: product.ingredients.joined(separator: " ")))
                let allProductTerms = identityTerms.union(productIngredientTerms)
                let overlap = combinedTerms.intersection(allProductTerms).count
                guard overlap > 0 else { return nil }

                var score = overlap * 18
                score += titleTerms.intersection(identityTerms).count * 24
                score += ingredientTerms.intersection(productIngredientTerms).count * 10
                score += product.dataCompletenessScore * 3

                if !normalizedTitle.isEmpty,
                   normalizedComparableText(product.name).contains(normalizedTitle) {
                    score += 30
                }
                return (product: product, score: score)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.product.lastUpdatedAt > rhs.product.lastUpdatedAt
                }
                return lhs.score > rhs.score
            }

        guard let top = rankedCandidates.first, top.score >= 35 else {
            return nil
        }
        return top.product
    }

    private func heuristicNutritionEstimate(for query: String) -> NutritionInferenceEstimate? {
        let normalized = normalizedComparableText(query)
        let estimate: (nutrition: NutritionFacts, serving: String, ingredients: [String])?

        if normalized.contains("pizza") {
            estimate = (
                nutrition: NutritionFacts(calories: 285, protein: 12, carbs: 36, fat: 10, fiber: 2),
                serving: "1 slice",
                ingredients: ["Wheat flour", "Tomato", "Mozzarella"]
            )
        } else if normalized.contains("burger") {
            estimate = (
                nutrition: NutritionFacts(calories: 354, protein: 17, carbs: 29, fat: 17, fiber: 1),
                serving: "1 burger",
                ingredients: ["Beef", "Bun", "Oil"]
            )
        } else if normalized.contains("salad") {
            estimate = (
                nutrition: NutritionFacts(calories: 120, protein: 4, carbs: 10, fat: 7, fiber: 3),
                serving: "1 bowl",
                ingredients: ["Leafy greens", "Vegetables", "Dressing"]
            )
        } else if normalized.contains("oatmeal") {
            estimate = (
                nutrition: NutritionFacts(calories: 150, protein: 5, carbs: 27, fat: 3, fiber: 4),
                serving: "1 cup",
                ingredients: ["Oats", "Water"]
            )
        } else if normalized.contains("chicken") && normalized.contains("breast") {
            estimate = (
                nutrition: NutritionFacts(calories: 165, protein: 31, carbs: 0, fat: 4, fiber: 0),
                serving: "1 cooked breast",
                ingredients: ["Chicken breast"]
            )
        } else if normalized.contains("rice") {
            estimate = (
                nutrition: NutritionFacts(calories: 205, protein: 4, carbs: 45, fat: 0.4, fiber: 1),
                serving: "1 cup cooked",
                ingredients: ["Rice"]
            )
        } else {
            estimate = nil
        }

        guard let estimate else { return nil }
        return NutritionInferenceEstimate(
            nutrition: estimate.nutrition,
            servingDescription: estimate.serving,
            ingredients: estimate.ingredients,
            sourceSummary: "Estimated from a built-in nutrition heuristic."
        )
    }

    private func storeAliases(for normalizedStore: String) -> [String] {
        switch normalizedStore {
        case "whole foods", "whole foods market":
            return ["whole foods", "whole foods market", "wholefoods"]
        case "trader joes", "trader joe s":
            return ["trader joes", "trader joe s", "trader joe"]
        case "sprouts", "sprouts farmers market":
            return ["sprouts", "sprouts farmers market"]
        default:
            return [normalizedStore]
        }
    }

    private func matchesSearchQuery(_ product: Product) -> Bool {
        let trimmed = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let parsedQuery = parseSearchQuery(trimmed)
        let queryTerms = parsedQuery.requiredTerms
        guard !queryTerms.isEmpty else { return true }

        let nameTerms = Set(normalizedTerms(for: product.name))
        let brandTerms = Set(normalizedTerms(for: product.brand))
        let storeTerms = Set(normalizedTerms(for: product.stores.joined(separator: " ")))

        if queryTerms.count == 1, let term = queryTerms.first {
            let strongIdentityMatch =
                nameTerms.contains(term)
                || brandTerms.contains(term)
                || storeTerms.contains(term)
                || nameTerms.contains(where: { isFuzzyTokenMatch(query: term, candidate: $0) })
                || brandTerms.contains(where: { isFuzzyTokenMatch(query: term, candidate: $0) })
                || storeTerms.contains(where: { isFuzzyTokenMatch(query: term, candidate: $0) })
            if !strongIdentityMatch {
                return false
            }
        }

        let haystack = [
            product.name,
            product.brand,
            product.barcode,
            product.ingredients.joined(separator: " "),
            product.stores.joined(separator: " ")
        ]
        .joined(separator: " ")
        .lowercased()
        let haystackTerms = normalizedTerms(for: haystack)

        return queryTerms.allSatisfy { term in
            if haystack.contains(term) {
                return true
            }

            return haystackTerms.contains { candidate in
                isFuzzyTokenMatch(query: term, candidate: candidate)
            }
        }
    }

    private func parseSearchQuery(_ rawQuery: String) -> (requiredTerms: [String], optionalStoreTerms: [String]) {
        let terms = normalizedTerms(for: rawQuery)
        let normalized = normalizedComparableText(rawQuery)
        var optionalStoreTerms: Set<String> = []
        var removableTerms: Set<String> = []

        if normalized.contains("whole foods") || normalized.contains("wholefoods") {
            optionalStoreTerms.formUnion(["whole", "foods", "wholefoods", "market", "wfm"])
            removableTerms.formUnion(["whole", "foods", "wholefoods", "wfm"])
        }

        if normalized.contains("trader joe") || normalized.contains("traderjoes") {
            optionalStoreTerms.formUnion(["trader", "joe", "joes", "traderjoe", "traderjoes"])
            removableTerms.formUnion(["trader", "joe", "joes", "traderjoe", "traderjoes"])
        }

        if normalized.contains("sprouts") {
            optionalStoreTerms.formUnion(["sprouts", "farmers", "market"])
            removableTerms.formUnion(["sprouts"])
        }

        let required = terms.filter { !removableTerms.contains($0) }
        return (required.isEmpty ? terms : required, Array(optionalStoreTerms))
    }

    private func normalizedTerms(for string: String) -> [String] {
        string
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private func isFuzzyTokenMatch(query: String, candidate: String) -> Bool {
        let lengthGap = abs(query.count - candidate.count)
        if lengthGap > 2 { return false }

        let distance = levenshteinDistance(query, candidate)
        if query.count <= 5 {
            return distance <= 1
        }
        return distance <= 2
    }

    private func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)

        if lhsChars.isEmpty { return rhsChars.count }
        if rhsChars.isEmpty { return lhsChars.count }

        var previousRow = Array(0...rhsChars.count)
        for (i, lhsChar) in lhsChars.enumerated() {
            var currentRow = [i + 1]
            for (j, rhsChar) in rhsChars.enumerated() {
                let insertion = currentRow[j] + 1
                let deletion = previousRow[j + 1] + 1
                let substitution = previousRow[j] + (lhsChar == rhsChar ? 0 : 1)
                currentRow.append(min(insertion, deletion, substitution))
            }
            previousRow = currentRow
        }

        return previousRow[rhsChars.count]
    }

    private func combinedRankingScore(for product: Product) -> Int {
        let favoriteBoost = isFavorite(product) ? 80 : 0
        let recentBoost = recentLoggedProductIDs.contains(product.id) ? 25 : 0
        let usageBoost = usageCounts[product.id, default: 0] * 5
        let completenessBoost = productQualityScore(for: product)
        let ratingBoost: Int
        switch analysis(for: product).rating {
        case .green: ratingBoost = 20
        case .yellow: ratingBoost = 8
        case .red: ratingBoost = 0
        }

        let queryBoost: Int
        if activeSearchQuery.isEmpty {
            queryBoost = 0
        } else {
            let normalizedName = normalizedComparableText(product.name)
            let normalizedBrand = normalizedComparableText(product.brand)
            let trimmed = normalizedComparableText(activeSearchQuery)
            if normalizedName == trimmed || normalizedBrand == trimmed {
                queryBoost = 50
            } else if normalizedName.contains(trimmed) || normalizedBrand.contains(trimmed) {
                queryBoost = 35
            } else {
                let nameTerms = Set(normalizedTerms(for: normalizedName))
                let brandTerms = Set(normalizedTerms(for: normalizedBrand))
                let ingredientTerms = Set(normalizedTerms(for: normalizedComparableText(product.ingredients.joined(separator: " "))))
                let parsedQuery = parseSearchQuery(activeSearchQuery)
                let hits = parsedQuery.requiredTerms.reduce(into: 0) { partial, term in
                    if nameTerms.contains(term) {
                        partial += 10
                    } else if nameTerms.contains(where: { isFuzzyTokenMatch(query: term, candidate: $0) }) {
                        partial += 7
                    }

                    if brandTerms.contains(term) {
                        partial += 6
                    } else if brandTerms.contains(where: { isFuzzyTokenMatch(query: term, candidate: $0) }) {
                        partial += 5
                    }

                    if ingredientTerms.contains(term) {
                        partial += 3
                    } else if ingredientTerms.contains(where: { isFuzzyTokenMatch(query: term, candidate: $0) }) {
                        partial += 2
                    }
                }
                let singleTermAdjustment: Int
                if parsedQuery.requiredTerms.count == 1, let term = parsedQuery.requiredTerms.first {
                    let normalizedNameContainsTerm = normalizedName.contains(term)
                    let normalizedBrandContainsTerm = normalizedBrand.contains(term)
                    let nameHasTerm = normalizedNameContainsTerm || nameTerms.contains(term)
                    let brandHasTerm = normalizedBrandContainsTerm || brandTerms.contains(term)
                    let ingredientHasTerm = ingredientTerms.contains(term)

                    var adjustment = 0
                    if nameHasTerm {
                        adjustment += 26
                    } else if brandHasTerm {
                        adjustment += 12
                    } else if ingredientHasTerm {
                        // Demote products where the query only appears incidentally in ingredients.
                        adjustment -= 18
                    }

                    if ingredientHasTerm, !nameHasTerm, isLikelyCompositeFoodName(normalizedName) {
                        adjustment -= 10
                    }
                    singleTermAdjustment = adjustment
                } else {
                    singleTermAdjustment = 0
                }
                let storeTerms = Set(normalizedTerms(for: normalizedComparableText(product.stores.joined(separator: " "))))
                let storeHintHits = parsedQuery.optionalStoreTerms.reduce(into: 0) { partial, term in
                    if storeTerms.contains(term) {
                        partial += 3
                    } else if storeTerms.contains(where: { isFuzzyTokenMatch(query: term, candidate: $0) }) {
                        partial += 2
                    }
                }
                queryBoost = hits + min(12, storeHintHits) + singleTermAdjustment
            }
        }

        let sourceBoost: Int
        switch product.source {
        case .seed: sourceBoost = 6
        case .openFoodFacts: sourceBoost = 4
        case .upcItemDB: sourceBoost = 1
        case .usda: sourceBoost = 2
        case .deepSearch: sourceBoost = 3
        case .manual: sourceBoost = 5
        }
        let completenessPenalty = product.isLowConfidenceCatalogEntry ? -30 : 0
        return favoriteBoost + recentBoost + usageBoost + completenessBoost + ratingBoost + queryBoost + sourceBoost + completenessPenalty
    }

    private func isLikelyCompositeFoodName(_ normalizedName: String) -> Bool {
        if normalizedName.contains(" and ") || normalizedName.contains("&") || normalizedName.contains(",") {
            return true
        }

        let compositeKeywords = [
            "salad", "sandwich", "wrap", "pizza", "pasta", "bowl", "meal",
            "waffle", "hummus", "guacamole", "dip", "soup", "quiche",
            "tortelloni", "dhal", "burger", "sausage"
        ]
        return compositeKeywords.contains { normalizedName.contains($0) }
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
        let normalizedProducts = products.map(withInferredStores)
        let normalizedCachedProducts = cachedProducts.map(withInferredStores)
        let merged = bestProductsByCanonicalKey(normalizedProducts + normalizedCachedProducts)
        let trimmed = merged
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .prefix(maxCachedProducts)
            .map { $0 }
        if trimmed != cachedProducts {
            cachedProducts = trimmed
            trimCachedProductsIfNeeded()
        }
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

    private func deepSearchQueryCacheKey(for query: String) -> String {
        "query:\(normalizedSearchKey(for: query))"
    }

    private func deepSearchProductCacheKey(for product: Product, scope: DeepSearchScope) -> String {
        "product:\(product.id):\(scope.rawValue)"
    }

    private func productQualityScore(for product: Product) -> Int {
        let userEditedBoost = product.isUserEdited ? 40 : 0
        return (product.dataCompletenessScore * 6) + userEditedBoost
    }

    private func preferredProductOrder(lhs: Product, rhs: Product) -> Bool {
        let lhsScore = productQualityScore(for: lhs)
        let rhsScore = productQualityScore(for: rhs)
        if lhsScore != rhsScore {
            return lhsScore < rhsScore
        }
        return lhs.lastUpdatedAt < rhs.lastUpdatedAt
    }

    private func isSameProductIdentity(lhs: Product, rhs: Product) -> Bool {
        if lhs.id == rhs.id { return true }
        if lhs.canonicalLookupKey == rhs.canonicalLookupKey { return true }

        let lhsBarcode = BarcodeNormalizer.digitsOnly(from: lhs.barcode)
        let rhsBarcode = BarcodeNormalizer.digitsOnly(from: rhs.barcode)
        if !lhsBarcode.isEmpty, lhsBarcode == rhsBarcode {
            return true
        }
        return false
    }

    private func runDeepSearch(for query: String) async {
        resetDeepSearchDebugLog()
        pendingDeepSearchProposal = nil
        let cacheKey = deepSearchQueryCacheKey(for: query)
        if let cached = deepSearchCache[cacheKey], isFresh(cached.cachedAt, ttl: deepSearchCacheTTL) {
            if let cachedProduct = cached.product {
                deepSearchResult = cachedProduct
                mergeIntoCache([cachedProduct])
                searchError = nil
                appendDeepSearchLog("Used cached deep search result for query: \(query)")
                return
            }
            appendDeepSearchLog("Used cached deep search miss for query: \(query)")
            if remoteSearchResults.isEmpty, localProductResults.isEmpty, matchingMeals.isEmpty {
                searchError = "No matching foods found, including deep search."
            }
            return
        }

        isDeepSearching = true
        activeDeepSearchProductID = nil
        activeDeepSearchScope = .all
        appendDeepSearchLog("Starting manual deep search for query: \(query)")
        defer { isDeepSearching = false }
        defer {
            activeDeepSearchProductID = nil
            activeDeepSearchScope = nil
        }

        do {
            appendDeepSearchLog("Querying fallback sources.")
            if let enriched = try await deepSearchService.deepSearchProduct(matching: query) {
                deepSearchCache[cacheKey] = CachedProductValue(product: enriched, cachedAt: .now)
                deepSearchResult = enriched
                mergeIntoCache([enriched])
                searchError = nil
                appendDeepSearchLog("Deep search found and cached: \(enriched.name)")
            } else if remoteSearchResults.isEmpty, localProductResults.isEmpty, matchingMeals.isEmpty {
                deepSearchCache[cacheKey] = CachedProductValue(product: nil, cachedAt: .now)
                searchError = "No matching foods found, including deep search."
                appendDeepSearchLog("Deep search completed with no match.")
            } else {
                deepSearchCache[cacheKey] = CachedProductValue(product: nil, cachedAt: .now)
                appendDeepSearchLog("Deep search completed but did not improve current results.")
            }
            persistState()
        } catch {
            if remoteSearchResults.isEmpty, localProductResults.isEmpty, matchingMeals.isEmpty {
                searchError = "No matching foods found, and deep search failed."
            }
            appendDeepSearchLog("Deep search failed: \(error.localizedDescription)")
        }
    }

    private func merge(product: Product, with enriched: Product, scope: DeepSearchScope) -> Product {
        var merged = product

        switch scope {
        case .all:
            if !enriched.name.isEmpty { merged.name = enriched.name }
            if enriched.brand != "Unknown Brand" { merged.brand = enriched.brand }
            if !enriched.barcode.isEmpty { merged.barcode = enriched.barcode }
            if !enriched.stores.isEmpty { merged.stores = enriched.stores }
            if enriched.servingDescription != "1 serving" { merged.servingDescription = enriched.servingDescription }
            if !enriched.ingredients.isEmpty { merged.ingredients = enriched.ingredients }
            if enriched.hasMeaningfulNutrition { merged.nutrition = enriched.nutrition }
            if enriched.imageURL != nil { merged.imageURL = enriched.imageURL }
        case .macros:
            if enriched.hasMeaningfulNutrition {
                merged.nutrition = enriched.nutrition
            }
            if enriched.servingDescription != "1 serving" {
                merged.servingDescription = enriched.servingDescription
            }
        case .ingredients:
            if !enriched.ingredients.isEmpty {
                merged.ingredients = enriched.ingredients
            }
        case .stores:
            if !enriched.stores.isEmpty {
                merged.stores = enriched.stores
            }
        }

        merged.lastUpdatedAt = .now
        return merged
    }

    private func buildDeepSearchProposal(for product: Product, candidate: Product, scope: DeepSearchScope) -> DeepSearchProposal? {
        let merged = merge(product: product, with: candidate, scope: scope)
        let changedFields = diffFields(from: product, to: merged)
        appendDeepSearchLog(candidateDebugSummary(candidate))
        appendDeepSearchLog("Candidate proposed changes: \(changedFieldsSummary(changedFields)).")

        guard !changedFields.isEmpty else {
            appendDeepSearchLog("Rejected candidate because it would not change any fields.")
            return nil
        }

        let infoGain = changedFields.filter(\.addsMissingData)
        guard !infoGain.isEmpty else {
            appendDeepSearchLog("Rejected candidate because it did not fill any missing sections.")
            return nil
        }

        let match = evaluateDeepSearchMatch(existing: product, candidate: candidate, scope: scope, changedFields: changedFields)
        for reason in match.reasons {
            appendDeepSearchLog(reason)
        }

        if !match.accepted {
            appendDeepSearchLog("Rejected candidate with confidence score \(match.score).")
            return nil
        }

        appendDeepSearchLog("Accepted candidate for review with confidence score \(match.score).")
        return DeepSearchProposal(
            productID: product.id,
            candidateProduct: candidate,
            mergedProduct: merged,
            scope: scope.rawValue,
            confidenceScore: match.score,
            confidenceReasons: match.reasons,
            changedFields: changedFields
        )
    }

    private func diffFields(from original: Product, to updated: Product) -> [DeepSearchFieldDiff] {
        var diffs: [DeepSearchFieldDiff] = []

        if normalizedComparableText(original.name) != normalizedComparableText(updated.name) {
            diffs.append(
                DeepSearchFieldDiff(
                    kind: .name,
                    label: "Name",
                    oldValue: original.name,
                    newValue: updated.name,
                    addsMissingData: false
                )
            )
        }

        if normalizedComparableText(original.brand) != normalizedComparableText(updated.brand) {
            diffs.append(
                DeepSearchFieldDiff(
                    kind: .brand,
                    label: "Brand",
                    oldValue: original.brand,
                    newValue: updated.brand,
                    addsMissingData: normalizedComparableText(original.brand).isEmpty || original.brand == "Unknown Brand"
                )
            )
        }

        if BarcodeNormalizer.digitsOnly(from: original.barcode) != BarcodeNormalizer.digitsOnly(from: updated.barcode) {
            diffs.append(
                DeepSearchFieldDiff(
                    kind: .barcode,
                    label: "Barcode",
                    oldValue: valueOrPlaceholder(original.barcode),
                    newValue: valueOrPlaceholder(updated.barcode),
                    addsMissingData: BarcodeNormalizer.digitsOnly(from: original.barcode).isEmpty && !BarcodeNormalizer.digitsOnly(from: updated.barcode).isEmpty
                )
            )
        }

        if normalizedComparableText(original.servingDescription) != normalizedComparableText(updated.servingDescription) {
            diffs.append(
                DeepSearchFieldDiff(
                    kind: .serving,
                    label: "Serving",
                    oldValue: original.servingDescription,
                    newValue: updated.servingDescription,
                    addsMissingData: original.servingDescription == "1 serving" && updated.servingDescription != "1 serving"
                )
            )
        }

        if Set(original.stores) != Set(updated.stores) {
            diffs.append(
                DeepSearchFieldDiff(
                    kind: .stores,
                    label: "Stores",
                    oldValue: original.stores.isEmpty ? "Missing" : original.stores.joined(separator: ", "),
                    newValue: updated.stores.isEmpty ? "Missing" : updated.stores.joined(separator: ", "),
                    addsMissingData: original.stores.isEmpty && !updated.stores.isEmpty
                )
            )
        }

        if original.ingredients != updated.ingredients {
            diffs.append(
                DeepSearchFieldDiff(
                    kind: .ingredients,
                    label: "Ingredients",
                    oldValue: summarizeIngredients(original.ingredients),
                    newValue: summarizeIngredients(updated.ingredients),
                    addsMissingData: !original.hasIngredientDetails && updated.hasIngredientDetails
                )
            )
        }

        if original.nutrition != updated.nutrition {
            diffs.append(
                DeepSearchFieldDiff(
                    kind: .macros,
                    label: "Macros",
                    oldValue: summarizeNutrition(original.nutrition),
                    newValue: summarizeNutrition(updated.nutrition),
                    addsMissingData: nutritionAddsMissingData(original: original.nutrition, updated: updated.nutrition)
                )
            )
        }

        if original.imageURL != updated.imageURL {
            diffs.append(
                DeepSearchFieldDiff(
                    kind: .image,
                    label: "Image",
                    oldValue: original.imageURL == nil ? "Missing" : "Present",
                    newValue: updated.imageURL == nil ? "Missing" : "Present",
                    addsMissingData: original.imageURL == nil && updated.imageURL != nil
                )
            )
        }

        return diffs
    }

    private func evaluateDeepSearchMatch(
        existing: Product,
        candidate: Product,
        scope: DeepSearchScope,
        changedFields: [DeepSearchFieldDiff]
    ) -> (accepted: Bool, score: Int, reasons: [String]) {
        var score = 0
        var reasons: [String] = []

        let existingBarcode = BarcodeNormalizer.digitsOnly(from: existing.barcode)
        let candidateBarcode = BarcodeNormalizer.digitsOnly(from: candidate.barcode)
        let barcodeVariants = Set(BarcodeNormalizer.variants(for: existingBarcode))
        let hasExistingBarcode = !existingBarcode.isEmpty

        if hasExistingBarcode {
            guard !candidateBarcode.isEmpty else {
                reasons.append("Barcode required for approval: existing item has barcode \(existingBarcode), candidate has none.")
                return (false, -200, reasons)
            }

            guard barcodeVariants.contains(candidateBarcode) else {
                reasons.append("Barcode mismatch: existing \(existingBarcode), candidate \(candidateBarcode).")
                return (false, -200, reasons)
            }

            score += 120
            reasons.append("Barcode matched exactly or via normalized variant.")
        } else {
            reasons.append("Existing item has no barcode, using fallback name/brand/macros matching.")
        }

        let nameOverlap = overlapScore(lhs: existing.name, rhs: candidate.name)
        score += Int((nameOverlap - 0.5) * 80)
        reasons.append("Name overlap score: \(Int((nameOverlap * 100).rounded()))%.")

        let existingBrand = normalizedComparableText(existing.brand)
        let candidateBrand = normalizedComparableText(candidate.brand)
        var brandOverlap: Double = 0
        if !existingBrand.isEmpty, existing.brand != "Unknown Brand", !candidateBrand.isEmpty, candidate.brand != "Unknown Brand" {
            brandOverlap = overlapScore(lhs: existing.brand, rhs: candidate.brand)
            score += Int((brandOverlap - 0.5) * 40)
            reasons.append("Brand overlap score: \(Int((brandOverlap * 100).rounded()))%.")
        }

        if existing.hasMeaningfulNutrition, candidate.hasMeaningfulNutrition {
            let macroDrift = macroDifferenceScore(lhs: existing.nutrition, rhs: candidate.nutrition)
            score += macroDrift.scoreAdjustment
            reasons.append(macroDrift.reason)
        } else {
            reasons.append("Macro comparison skipped because one side lacks nutrition.")
        }

        if !hasExistingBarcode, existing.hasMeaningfulNutrition {
            guard candidate.hasMeaningfulNutrition else {
                reasons.append("Fallback match rejected: existing item has macros but candidate does not.")
                return (false, -150, reasons)
            }

            let fallbackMacroCheck = macroDifferenceScore(lhs: existing.nutrition, rhs: candidate.nutrition)
            let fillsIngredients = changedFields.contains { $0.kind == .ingredients && $0.addsMissingData }
            let ingredientTargeted = scope == .ingredients || scope == .all
            if fallbackMacroCheck.scoreAdjustment < 5, !(fillsIngredients && ingredientTargeted && nameOverlap >= 0.65) {
                reasons.append("Fallback match rejected: macro alignment too weak without barcode.")
                return (false, -150, reasons)
            }
            if fallbackMacroCheck.scoreAdjustment < 5, fillsIngredients && ingredientTargeted && nameOverlap >= 0.65 {
                reasons.append("Accepted weaker macro alignment because candidate fills missing ingredients with strong name overlap.")
            }
        }

        let hasStrongIdentityMatch: Bool
        if hasExistingBarcode {
            hasStrongIdentityMatch = true
        } else {
            hasStrongIdentityMatch = nameOverlap >= 0.75 || (nameOverlap >= 0.65 && brandOverlap >= 0.5)
        }

        let accepted = hasStrongIdentityMatch && score >= 20
        return (accepted, score, reasons)
    }

    private func candidateDebugSummary(_ candidate: Product) -> String {
        "Candidate snapshot -> source: \(candidate.source.rawValue), name: \(candidate.name), brand: \(candidate.brand), ingredients: \(candidate.ingredients.count), macros: \(summarizeNutrition(candidate.nutrition)), stores: \(candidate.stores.isEmpty ? "none" : candidate.stores.joined(separator: ", ")), barcode: \(valueOrPlaceholder(candidate.barcode))."
    }

    private func changedFieldsSummary(_ fields: [DeepSearchFieldDiff]) -> String {
        guard !fields.isEmpty else { return "none" }
        return fields.map { field in
            let changeType = field.addsMissingData ? "fills missing" : "changes existing"
            return "\(field.label): \(changeType)"
        }.joined(separator: " | ")
    }

    private func overlapScore(lhs: String, rhs: String) -> Double {
        let lhsTerms = Set(normalizedTerms(for: lhs))
        let rhsTerms = Set(normalizedTerms(for: rhs))
        guard !lhsTerms.isEmpty, !rhsTerms.isEmpty else { return 0 }
        let intersection = lhsTerms.intersection(rhsTerms).count
        let union = lhsTerms.union(rhsTerms).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func macroDifferenceScore(lhs: NutritionFacts, rhs: NutritionFacts) -> (scoreAdjustment: Int, reason: String) {
        func close(_ a: Double, _ b: Double, tolerance: Double) -> Bool {
            abs(a - b) <= tolerance
        }

        let caloriesClose = abs(lhs.calories - rhs.calories) <= 20
        let proteinClose = close(lhs.protein, rhs.protein, tolerance: 3)
        let carbsClose = close(lhs.carbs, rhs.carbs, tolerance: 3)
        let fatClose = close(lhs.fat, rhs.fat, tolerance: 3)
        let exactishMatches = [caloriesClose, proteinClose, carbsClose, fatClose].filter { $0 }.count

        if exactishMatches >= 3 {
            return (20, "Macros are close to the existing entry.")
        }

        if exactishMatches == 2 {
            return (5, "Macros are partially aligned with the existing entry.")
        }

        return (-35, "Macros drift too far from the existing entry.")
    }

    private func nutritionAddsMissingData(original: NutritionFacts, updated: NutritionFacts) -> Bool {
        let originalHasMacros = original.calories > 0 || original.protein > 0 || original.carbs > 0 || original.fat > 0 || original.fiber > 0
        let updatedHasMacros = updated.calories > 0 || updated.protein > 0 || updated.carbs > 0 || updated.fat > 0 || updated.fiber > 0
        if !originalHasMacros && updatedHasMacros {
            return true
        }

        // Even if core macros already exist, filling missing fiber is still useful missing data.
        if original.fiber <= 0.01, updated.fiber > 0.01 {
            return true
        }

        return false
    }

    private func normalizedComparableText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func valueOrPlaceholder(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Missing" : trimmed
    }

    private func summarizeIngredients(_ ingredients: [String]) -> String {
        guard !ingredients.isEmpty else { return "Missing" }
        let preview = ingredients.prefix(3).joined(separator: ", ")
        if ingredients.count > 3 {
            return "\(preview) +\(ingredients.count - 3) more"
        }
        return preview
    }

    private func summarizeNutrition(_ nutrition: NutritionFacts) -> String {
        guard nutrition != .zero else { return "Missing" }
        return "\(nutrition.calories) cal, \(Int(nutrition.protein.rounded()))g P, \(Int(nutrition.carbs.rounded()))g C, \(Int(nutrition.fat.rounded()))g F, \(Int(nutrition.fiber.rounded()))g Fi"
    }

    private func setupPersistence() {
        $selectedDiet
            .sink { [weak self] _ in
                self?.clearAnalysisCache()
                self?.persistState()
            }
            .store(in: &cancellables)
        $goals
            .sink { [weak self] _ in self?.persistState(includeWidgetSnapshot: true) }
            .store(in: &cancellables)
        $cachedProducts
            .sink { [weak self] _ in self?.persistState() }
            .store(in: &cancellables)
        $meals
            .sink { [weak self] _ in self?.persistState() }
            .store(in: &cancellables)
        $loggedFoods
            .sink { [weak self] _ in self?.persistState(includeWidgetSnapshot: true) }
            .store(in: &cancellables)
        $usageCounts
            .sink { [weak self] _ in self?.persistState() }
            .store(in: &cancellables)
        $favoriteProductKeys
            .sink { [weak self] _ in self?.persistState() }
            .store(in: &cancellables)
        $favoriteImportJobs
            .sink { [weak self] _ in self?.persistState() }
            .store(in: &cancellables)
    }

    private func persistState(includeWidgetSnapshot: Bool = false) {
        pruneExpiredCaches()
        persistence.save(
            PersistedAppState(
                selectedDiet: selectedDiet,
                goals: goals,
                cachedProducts: cachedProducts,
                favoriteProductKeys: Array(favoriteProductKeys),
                meals: meals,
                loggedFoods: loggedFoods,
                usageCounts: usageCounts,
                searchCacheByQuery: searchCache,
                barcodeCache: barcodeCache,
                deepSearchCache: deepSearchCache,
                favoriteImportJobs: favoriteImportJobs
            ),
            includeWidgetSnapshot: includeWidgetSnapshot
        )
    }

    private func pruneExpiredCaches() {
        searchCache = searchCache.filter { isFresh($0.value.cachedAt, ttl: catalogCacheTTL) }
        barcodeCache = barcodeCache.filter { isFresh($0.value.cachedAt, ttl: catalogCacheTTL) }
        deepSearchCache = deepSearchCache.filter { isFresh($0.value.cachedAt, ttl: deepSearchCacheTTL) }
    }

    private func isFresh(_ timestamp: Date, ttl: TimeInterval) -> Bool {
        Date().timeIntervalSince(timestamp) <= ttl
    }

    private func resetDeepSearchDebugLog() {
        deepSearchDebugLog = []
    }

    private func appendDeepSearchLog(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        deepSearchDebugLog.append("[\(timestamp)] \(message)")
    }

    private func startFiberBackfillIfNeeded() {
        guard !didStartFiberBackfill else { return }
        didStartFiberBackfill = true
        Task { [weak self] in
            await self?.backfillMissingFiberNutrition()
        }
    }

    private func rebuildLocalCatalogSnapshot() {
        let normalized = (SampleData.products + cachedProducts).map(withInferredStores)
        localCatalogSnapshot = deduplicatedProductsByID(bestProductsByCanonicalKey(normalized))
    }

    private func rebuildRecentLoggedProductIDs() {
        recentLoggedProductIDs = Set(loggedFoods.flatMap(\.sourceProductIDs))
    }

    private func clearAnalysisCache() {
        analysisCache.removeAll(keepingCapacity: true)
    }

    private func analysisCacheKey(for product: Product) -> String {
        "\(selectedDiet.rawValue)|\(product.id)|\(product.lastUpdatedAt.timeIntervalSince1970)"
    }

    private func trimCachedProductsIfNeeded() {
        guard cachedProducts.count > maxCachedProducts else { return }

        let pinnedIDs = Set(favoriteProducts.map(\.id))
            .union(loggedFoods.flatMap(\.sourceProductIDs))
            .union(meals.flatMap { $0.components.map(\.product.id) })

        let ordered = cachedProducts.sorted { lhs, rhs in
            let lhsPinned = pinnedIDs.contains(lhs.id)
            let rhsPinned = pinnedIDs.contains(rhs.id)
            if lhsPinned != rhsPinned { return lhsPinned && !rhsPinned }
            return lhs.lastUpdatedAt > rhs.lastUpdatedAt
        }

        cachedProducts = Array(ordered.prefix(maxCachedProducts))
    }

    private func backfillMissingFiberNutrition() async {
        let candidates = deduplicatedProductsByID(bestProductsByCanonicalKey(cachedProducts))
            .filter { product in
                product.nutrition.fiber <= 0.01
                    && (product.hasMeaningfulNutrition || !product.barcode.isEmpty)
                    && (product.source == .openFoodFacts || product.source == .upcItemDB || product.source == .deepSearch || product.source == .manual)
            }
            .prefix(30)

        guard !candidates.isEmpty else { return }

        var updates: [Product] = []
        for product in candidates {
            if Task.isCancelled { break }

            if let enriched = await backfilledFiberCandidate(for: product) {
                var merged = product
                merged.nutrition.fiber = enriched.nutrition.fiber
                merged.lastUpdatedAt = .now
                updates.append(merged)
            }
        }

        guard !updates.isEmpty else { return }
        mergeIntoCache(updates)

        if let deepSearchResult,
           let replacement = updates.first(where: { isSameProductIdentity(lhs: deepSearchResult, rhs: $0) }) {
            self.deepSearchResult = replacement
        }
        if let barcodeLookupResult,
           let replacement = updates.first(where: { isSameProductIdentity(lhs: barcodeLookupResult, rhs: $0) }) {
            self.barcodeLookupResult = replacement
        }
    }

    private func backfilledFiberCandidate(for product: Product) async -> Product? {
        let barcode = BarcodeNormalizer.digitsOnly(from: product.barcode)
        if !barcode.isEmpty,
           let fetched = try? await catalogService.product(forBarcode: barcode),
           fetched.nutrition.fiber > 0.01 {
            return withInferredStores(fetched)
        }

        let query = "\(product.brand) \(product.name)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return nil }

        guard let matches = try? await catalogService.searchProducts(matching: query) else { return nil }
        let best = matches.first { candidate in
            candidate.nutrition.fiber > 0.01
                && (candidate.canonicalLookupKey == product.canonicalLookupKey
                    || normalizedComparableText(candidate.name) == normalizedComparableText(product.name))
        }
        return best.map(withInferredStores)
    }

    private func parseWholeFoodsOrderItems(from payload: String, maxItems: Int) -> [ParsedOrderItem] {
        let lines = payload.components(separatedBy: .newlines)
        var seenNames: Set<String> = []
        var parsed: [ParsedOrderItem] = []

        for rawLine in lines {
            let normalizedLine = rawLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard !normalizedLine.isEmpty else { continue }
            let lowercase = normalizedLine.lowercased()
            if shouldIgnoreOrderLine(lowercase) { continue }

            var name = normalizedLine
            name = name.replacingOccurrences(of: #"(?i)^\s*(qty|quantity)\s*[:\-]?\s*\d+\s*"#, with: "", options: .regularExpression)
            name = name.replacingOccurrences(of: #"(?i)^\s*\d+\s*(x|×)\s*"#, with: "", options: .regularExpression)
            name = name.replacingOccurrences(of: #"(?i)\s+qty\s*[:\-]?\s*\d+\s*$"#, with: "", options: .regularExpression)
            name = name.replacingOccurrences(of: #"\$+\s*\d+(?:\.\d{1,2})?\s*$"#, with: "", options: .regularExpression)
            name = name.replacingOccurrences(of: #"(?i)\s+\((substitute|replacement).*\)\s*$"#, with: "", options: .regularExpression)
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)

            guard name.count >= 3 else { continue }
            let normalizedName = normalizedTerms(for: name).joined(separator: " ")
            guard normalizedName.count >= 3, seenNames.insert(normalizedName).inserted else { continue }

            parsed.append(ParsedOrderItem(name: name))
            if parsed.count >= maxItems { break }
        }

        return parsed
    }

    private func shouldIgnoreOrderLine(_ line: String) -> Bool {
        let ignoredKeywords = [
            "subtotal",
            "estimated total",
            "order total",
            "tip",
            "tax",
            "delivery",
            "service fee",
            "order #",
            "replacement preference",
            "arriving",
            "order placed",
            "item total",
            "payment",
            "refund",
            "coupon",
            "prime"
        ]
        if ignoredKeywords.contains(where: line.contains) {
            return true
        }
        if line.range(of: #"^\$?\d+(?:\.\d{1,2})?$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private func resolveWholeFoodsProduct(for itemName: String) async -> Product? {
        if let local = bestLocalMatch(forOrderItem: itemName) {
            if local.hasMeaningfulNutrition {
                return withInferredStores(local)
            }
            if let enriched = try? await deepSearchService.deepSearchProduct(for: local, scope: .all), enriched.hasMeaningfulNutrition {
                return withInferredStores(merge(product: local, with: enriched, scope: .all))
            }
            return withInferredStores(local)
        }

        let wholeFoodsQuery = "\(itemName) whole foods"
        async let catalogMatches = try? catalogService.searchProducts(matching: wholeFoodsQuery)
        async let deepSearchMatch = try? deepSearchService.deepSearchProduct(matching: wholeFoodsQuery)
        let wholeFoodsURL = URL(string: "https://www.wholefoodsmarket.com/search?text=\(wholeFoodsQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        let myFoodDiaryURL = URL(string: "https://www.myfooddiary.com/search?q=\(itemName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        async let wholeFoodsURLMatch: Product? = {
            guard let wholeFoodsURL else { return nil }
            return try? await deepSearchService.deepSearchProduct(from: wholeFoodsURL)
        }()
        async let myFoodDiaryMatch: Product? = {
            guard let myFoodDiaryURL else { return nil }
            return try? await deepSearchService.deepSearchProduct(from: myFoodDiaryURL)
        }()

        let candidates = (await catalogMatches ?? []) + [await deepSearchMatch, await wholeFoodsURLMatch, await myFoodDiaryMatch].compactMap { $0 }
        guard let selected = bestImportCandidate(from: candidates, orderItemName: itemName) else {
            return nil
        }

        if selected.hasMeaningfulNutrition {
            return withInferredStores(selected)
        }

        if let enriched = try? await deepSearchService.deepSearchProduct(for: selected, scope: .macros), enriched.hasMeaningfulNutrition {
            return withInferredStores(merge(product: selected, with: enriched, scope: .all))
        }

        return withInferredStores(selected)
    }

    private func bestLocalMatch(forOrderItem itemName: String) -> Product? {
        let itemTerms = Set(normalizedTerms(for: itemName))
        guard !itemTerms.isEmpty else { return nil }

        let ranked = localCatalog.compactMap { product -> (Product, Int)? in
            let haystack = "\(product.brand) \(product.name)"
            let productTerms = Set(normalizedTerms(for: haystack))
            guard !productTerms.isEmpty else { return nil }
            let overlap = itemTerms.intersection(productTerms).count
            guard overlap > 0 else { return nil }
            var score = overlap * 25
            if product.stores.contains(where: { normalizeStoreName($0).contains("whole foods") || normalizeStoreName($0).contains("wholefoods") }) {
                score += 20
            }
            if product.hasMeaningfulNutrition { score += 20 }
            score += product.dataCompletenessScore * 2
            return (product, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0.lastUpdatedAt > rhs.0.lastUpdatedAt }
            return lhs.1 > rhs.1
        }
        return ranked.first?.0
    }

    private func bestImportCandidate(from candidates: [Product], orderItemName: String) -> Product? {
        let itemTerms = Set(normalizedTerms(for: orderItemName))
        return candidates.max { lhs, rhs in
            importCandidateScore(lhs, itemTerms: itemTerms) < importCandidateScore(rhs, itemTerms: itemTerms)
        }
    }

    private func importCandidateScore(_ candidate: Product, itemTerms: Set<String>) -> Int {
        let text = "\(candidate.brand) \(candidate.name) \(candidate.stores.joined(separator: " "))".lowercased()
        let terms = Set(normalizedTerms(for: text))
        let overlap = itemTerms.intersection(terms).count

        var score = overlap * 20
        if candidate.stores.contains(where: { normalizeStoreName($0).contains("whole foods") || normalizeStoreName($0).contains("wholefoods") }) {
            score += 50
        }
        if text.contains("365 by whole foods") || text.contains("whole foods") {
            score += 35
        }
        if candidate.hasMeaningfulNutrition {
            score += 30
        }
        if candidate.hasIngredientDetails {
            score += 15
        }
        score += candidate.dataCompletenessScore * 5
        return score
    }

    private func withInferredStores(_ product: Product) -> Product {
        var normalized = product
        let inferred = inferredStoresFromBrandAndName(brand: product.brand, name: product.name)
        if !inferred.isEmpty {
            normalized.stores = Array(Set(normalized.stores + inferred)).sorted()
        }

        if isGenericServingDescription(normalized.servingDescription),
           let inferredServing = inferredServingDescription(for: normalized) {
            normalized.servingDescription = inferredServing
        }
        return normalized
    }

    private func isGenericServingDescription(_ value: String) -> Bool {
        let normalized = normalizedComparableText(value)
        return normalized.isEmpty || normalized == "1 serving" || normalized == "serving"
    }

    private func inferredServingDescription(for product: Product) -> String? {
        let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerName = name.lowercased()
        let context = "\(product.brand) \(product.name) \(product.ingredients.joined(separator: " "))".lowercased()

        if let match = firstRegexMatch(
            pattern: #"(\d+(?:\.\d+)?)\s*(eggs?|crackers?|chips?|cookies?|slices?|pieces?)\b"#,
            in: lowerName
        ) {
            let quantity = match.0
            let unit = match.1
            return "\(quantity) \(unit)"
        }

        if context.contains("egg") {
            return "1 egg"
        }
        if context.contains("cracker") || context.contains("wheat crisp") || context.contains("crisps") {
            return "5 crackers"
        }
        if context.contains("chip") {
            return "15 chips"
        }
        if context.contains("almond") || context.contains("nut") || context.contains("trail mix") || context.contains("seed") {
            return "1 oz (28 g)"
        }
        if context.contains("tofu") {
            return "3 oz (85 g)"
        }
        if context.contains("riced cauliflower") || context.contains("cauliflower rice") || context.contains("spinach") || context.contains("leafy") {
            return "1 cup"
        }
        if context.contains("oil") || context.contains("ghee") || context.contains("butter") {
            return "1 tbsp"
        }
        if context.contains("milk")
            || context.contains("kefir")
            || context.contains("kombucha")
            || context.contains("kvass")
            || context.contains("juice")
            || context.contains("soda")
            || context.contains("drink")
            || context.contains("beverage") {
            return "8 fl oz"
        }

        return nil
    }

    private func firstRegexMatch(pattern: String, in input: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = regex.firstMatch(in: input, options: [], range: nsRange),
              match.numberOfRanges >= 3,
              let quantityRange = Range(match.range(at: 1), in: input),
              let unitRange = Range(match.range(at: 2), in: input) else {
            return nil
        }
        let quantity = String(input[quantityRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = String(input[unitRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quantity.isEmpty, !unit.isEmpty else { return nil }
        return (quantity, unit)
    }

    private func inferredStoresFromBrandAndName(brand: String, name: String) -> [String] {
        let value = "\(brand) \(name)".lowercased()
        var stores: [String] = []

        if value.contains("trader joe") || value.contains("tj's") || value.contains("tjs") {
            stores.append("Trader Joe's")
        }
        if value.contains("whole foods") || value.contains("365 by whole foods") || value.contains("365 organic") {
            stores.append("Whole Foods")
        }
        if value.contains("kirkland") {
            stores.append("Costco")
        }
        if value.contains("good & gather") || value.contains("market pantry") {
            stores.append("Target")
        }

        return Array(Set(stores)).sorted()
    }

    private func roundedNumericText(in text: String) -> String {
        let pattern = #"\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let originalRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: originalRange).reversed()
        var result = text
        for match in matches {
            guard let sourceRange = Range(match.range, in: text),
                  let numericValue = Double(text[sourceRange]) else {
                continue
            }
            let replacement = numericValue.formatted(.number.precision(.fractionLength(0...2)))
            if let resultRange = Range(match.range, in: result) {
                result.replaceSubrange(resultRange, with: replacement)
            }
        }
        return result
    }
}

private struct ParsedOrderItem {
    var name: String
}
