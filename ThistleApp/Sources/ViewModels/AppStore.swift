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
            if products.isEmpty, localProductResults.isEmpty, matchingMeals.isEmpty {
                searchError = "No matching foods found in your local library or the online catalog."
            }
        } catch {
            remoteSearchResults = []
            searchError = error.localizedDescription
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

    func product(withID id: String) -> Product? {
        localCatalog.first(where: { $0.id == id })
    }

    func enrich(product: Product, scope: DeepSearchScope) async {
        resetDeepSearchDebugLog()
        pendingDeepSearchProposal = nil
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
            guard let enriched = try await deepSearchService.deepSearchProduct(for: product, scope: scope) else {
                appendDeepSearchLog("Deep search found no candidate.")
                return
            }
            appendDeepSearchLog("Deep search found a candidate: \(enriched.name).")
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

    private func runDeepSearch(for query: String) async {
        resetDeepSearchDebugLog()
        pendingDeepSearchProposal = nil
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
                deepSearchResult = enriched
                mergeIntoCache([enriched])
                searchError = nil
                appendDeepSearchLog("Deep search found and cached: \(enriched.name)")
            } else if remoteSearchResults.isEmpty, localProductResults.isEmpty, matchingMeals.isEmpty {
                searchError = "No matching foods found, including deep search."
                appendDeepSearchLog("Deep search completed with no match.")
            } else {
                appendDeepSearchLog("Deep search completed but did not improve current results.")
            }
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

        guard !changedFields.isEmpty else {
            appendDeepSearchLog("Rejected candidate because it would not change any fields.")
            return nil
        }

        let infoGain = changedFields.filter(\.addsMissingData)
        guard !infoGain.isEmpty else {
            appendDeepSearchLog("Rejected candidate because it did not fill any missing sections.")
            return nil
        }

        let match = evaluateDeepSearchMatch(existing: product, candidate: candidate)
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

    private func evaluateDeepSearchMatch(existing: Product, candidate: Product) -> (accepted: Bool, score: Int, reasons: [String]) {
        var score = 0
        var reasons: [String] = []

        let existingBarcode = BarcodeNormalizer.digitsOnly(from: existing.barcode)
        let candidateBarcode = BarcodeNormalizer.digitsOnly(from: candidate.barcode)
        let barcodeVariants = Set(BarcodeNormalizer.variants(for: existingBarcode))

        if !existingBarcode.isEmpty, !candidateBarcode.isEmpty {
            if barcodeVariants.contains(candidateBarcode) {
                score += 100
                reasons.append("Barcode matched exactly or via normalized variant.")
            } else {
                score -= 120
                reasons.append("Barcode mismatch: existing \(existingBarcode), candidate \(candidateBarcode).")
            }
        } else {
            reasons.append("No barcode match available, falling back to name/brand/macros.")
        }

        let nameOverlap = overlapScore(lhs: existing.name, rhs: candidate.name)
        score += Int((nameOverlap - 0.5) * 80)
        reasons.append("Name overlap score: \(Int((nameOverlap * 100).rounded()))%.")

        let existingBrand = normalizedComparableText(existing.brand)
        let candidateBrand = normalizedComparableText(candidate.brand)
        if !existingBrand.isEmpty, existing.brand != "Unknown Brand", !candidateBrand.isEmpty, candidate.brand != "Unknown Brand" {
            let brandOverlap = overlapScore(lhs: existing.brand, rhs: candidate.brand)
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

        let hasStrongIdentityMatch = (!existingBarcode.isEmpty && barcodeVariants.contains(candidateBarcode)) || nameOverlap >= 0.75
        let accepted = hasStrongIdentityMatch && score >= 20
        return (accepted, score, reasons)
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
        return "\(nutrition.calories) cal, \(Int(nutrition.protein.rounded()))g P, \(Int(nutrition.carbs.rounded()))g C, \(Int(nutrition.fat.rounded()))g F"
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

    private func resetDeepSearchDebugLog() {
        deepSearchDebugLog = []
    }

    private func appendDeepSearchLog(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        deepSearchDebugLog.append("[\(timestamp)] \(message)")
    }
}
