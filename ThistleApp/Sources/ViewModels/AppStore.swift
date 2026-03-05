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
    @Published var selectedTab: AppTab = .search
    @Published var selectedDiet: DietProfile = .whole30
    @Published var goals: MacroGoals = .default
    @Published var cachedProducts: [Product] = []
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
    @Published var deepSearchDebugLog: [String] = []
    @Published var activeDeepSearchProductID: String?
    @Published var activeDeepSearchScope: DeepSearchScope?
    @Published var pendingDeepSearchProposal: DeepSearchProposal?
    @Published var hasSubmittedSearch = false
    @Published var barcodeLookupResult: Product?
    @Published var barcodeLookupError: String?
    @Published var isLookingUpBarcode = false

    private let analyzer = IngredientAnalyzer()
    private let catalogService: ProductCatalogServing
    private let deepSearchService: DeepSearchServing
    private let persistence: AppPersistence
    private let catalogCacheTTL: TimeInterval = 60 * 60 * 24 * 7
    private let deepSearchCacheTTL: TimeInterval = 60 * 60 * 24
    private var cancellables: Set<AnyCancellable> = []
    private var searchCache: [String: CachedProductList] = [:]
    private var barcodeCache: [String: CachedProductValue] = [:]
    private var deepSearchCache: [String: CachedProductValue] = [:]

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
        }
        pruneExpiredCaches()

        setupPersistence()
    }

    var localCatalog: [Product] {
        deduplicatedProductsByID(bestProductsByCanonicalKey(SampleData.products + cachedProducts))
    }

    var mealBuilderProducts: [Product] {
        localCatalog.sorted { combinedRankingScore(for: $0) > combinedRankingScore(for: $1) }
    }

    var favoriteProducts: [Product] {
        localCatalog
            .filter(isFavorite)
            .sorted { combinedRankingScore(for: $0) > combinedRankingScore(for: $1) }
    }

    var availableStores: [String] {
        let candidates = localCatalog
            + remoteSearchResults
            + (deepSearchResult.map { [$0] } ?? [])
        return ["All Stores"] + Array(Set(candidates.flatMap(\.stores))).sorted()
    }

    var localProductResults: [Product] {
        let candidates = query.isEmpty ? localCatalog : localCatalog.filter(matchesSearchQuery)
        return candidates
            .filter(matchesFilters)
            .sorted { combinedRankingScore(for: $0) > combinedRankingScore(for: $1) }
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
        let combined = deduplicatedProductsByID(localProductResults + remoteSearchResults + (deepSearchResult.map { [$0] } ?? []))
        return combined
            .filter(shouldSurfaceSearchResult)
            .filter(matchesFilters)
            .sorted { combinedRankingScore(for: $0) > combinedRankingScore(for: $1) }
    }

    private func shouldSurfaceSearchResult(_ product: Product) -> Bool {
        if !product.isLowConfidenceCatalogEntry || !product.ingredients.isEmpty {
            return true
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
            if let cached = searchCache[cacheKey], isFresh(cached.cachedAt, ttl: catalogCacheTTL) {
                remoteSearchResults = cached.products
                mergeIntoCache(cached.products)
                if cached.products.isEmpty, localProductResults.isEmpty, matchingMeals.isEmpty {
                    searchError = "No matching foods found in your local library or the online catalog."
                }
                return
            }

            if let stale = searchCache[cacheKey], !stale.products.isEmpty {
                // Show stale results immediately, then refresh from network.
                remoteSearchResults = stale.products
                mergeIntoCache(stale.products)
            }

            let products = try await catalogService.searchProducts(matching: trimmed)
            if !products.isEmpty {
                searchCache[cacheKey] = CachedProductList(products: products, cachedAt: .now)
                persistState()
            } else {
                searchCache[cacheKey] = nil
            }

            remoteSearchResults = products
            mergeIntoCache(products)
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
                barcodeLookupResult = cached.product
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
            for variant in variants {
                barcodeCache[variant] = CachedProductValue(product: fetched, cachedAt: .now)
            }
            persistState()
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

    func resetBarcodeLookupState(clearManualBarcode: Bool = false) {
        barcodeLookupResult = nil
        barcodeLookupError = nil
        isLookingUpBarcode = false
        if clearManualBarcode {
            manualBarcode = ""
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

    func product(withID id: String) -> Product? {
        localCatalog.first(where: { $0.id == id })
    }

    func isFavorite(_ product: Product) -> Bool {
        favoriteProductKeys.contains(product.canonicalLookupKey)
    }

    func toggleFavorite(_ product: Product) {
        mergeIntoCache([product])
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

        let ingredients = ingredientsText
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let stores = storesText
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
                servingText: "Custom meal",
                sourceProductIDs: meal.components.map(\.product.id),
                sourceProductID: nil,
                loggedServings: nil,
                baseServingDescription: nil,
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

    func deleteLoggedFood(entryID: String) {
        loggedFoods.removeAll { $0.id == entryID }
    }

    func updateLoggedFoodServing(entryID: String, servings: Double) {
        guard let index = loggedFoods.firstIndex(where: { $0.id == entryID }) else { return }
        guard servings > 0 else { return }

        var entry = loggedFoods[index]
        if entry.sourceProductID == nil, entry.sourceProductIDs.count > 1 {
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
        case .manual: sourceBoost = 5
        }
        let completenessPenalty = product.isLowConfidenceCatalogEntry ? -30 : 0
        return favoriteBoost + recentBoost + usageBoost + completenessBoost + ratingBoost + queryBoost + sourceBoost + completenessPenalty
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
                    addsMissingData: !original.hasMeaningfulNutrition && updated.hasMeaningfulNutrition
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
        $favoriteProductKeys
            .sink { [weak self] _ in self?.persistState() }
            .store(in: &cancellables)
    }

    private func persistState() {
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
                deepSearchCache: deepSearchCache
            )
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
