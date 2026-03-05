import SwiftUI
import VisionKit

struct MealsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingBuilder = false
    @State private var editingMeal: SavedMeal?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button("New Meal") {
                        showingBuilder = true
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }

                ForEach(store.meals) { meal in
                    mealCard(meal)
                        .contextMenu {
                            Button("Edit Meal") {
                                editingMeal = meal
                            }
                            Button(role: .destructive) {
                                store.deleteMeal(mealID: meal.id)
                            } label: {
                                Text("Delete Meal")
                            }
                        }
                }
            }
            .padding()
        }
        .background(ThistleTheme.canvas.ignoresSafeArea())
        .thistleNavigationTitle("Meals")
        .sheet(isPresented: $showingBuilder) {
            MealBuilderView(existingMeal: nil)
        }
        .sheet(item: $editingMeal) { meal in
            MealBuilderView(existingMeal: meal)
        }
    }

    private func mealCard(_ meal: SavedMeal) -> some View {
        let analysis = store.analysis(for: meal)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meal.name)
                        .font(.headline)
                }
                Spacer()
                RatingBadge(rating: analysis.rating)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(meal.components) { component in
                    let componentAnalysis = store.analysis(for: component.product)
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(component.servings.formatted())x \(component.product.name)")
                                .font(.subheadline.weight(.semibold))
                            if !component.product.hasIngredientDetails {
                                Text("Missing ingredients")
                                    .font(.caption2)
                                    .foregroundStyle(ThistleTheme.warning)
                            }
                        }
                        Spacer(minLength: 8)
                        miniStatusBadge(rating: componentAnalysis.rating)
                    }
                }
            }

            MacroSummaryView(nutrition: meal.nutrition)

            if !analysis.flags.isEmpty {
                Text(analysis.flags.map(\.ingredient).joined(separator: ", "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(analysis.rating.color)
            }

            Button("Log Meal") {
                store.log(meal: meal)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func miniStatusBadge(rating: ComplianceRating) -> some View {
        Text(rating.title.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundStyle(rating.color)
            .background(rating.color.opacity(0.16), in: Capsule())
    }
}

struct MealBuilderView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let existingMeal: SavedMeal?
    @State private var name = ""
    @State private var productQuery = ""
    @State private var servingsByProduct: [String: Double] = [:]
    @State private var remoteSearchResults: [Product] = []
    @State private var semanticFallbackProduct: Product?
    @State private var isSearchingCatalog = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var hasSubmittedProductSearch = false
    @State private var previewProduct: Product?
    @State private var showingManualIngredientSheet = false
    @State private var showingBarcodeScanner = false
    @State private var scannedBarcode: String?
    @State private var didHydrateExistingMeal = false
    @State private var knownProducts: [Product] = []
    @State private var selectedProductCache: [String: Product] = [:]
    private let catalogService: ProductCatalogServing = ProductCatalogService()
    private let deepSearchService: DeepSearchServing = DeepSearchService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Meal Name") {
                    TextField("Whole30 Lunch Bowl", text: $name)
                }

                Section("Find Products") {
                    TextField("Search products or brands", text: $productQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            runProductSearch()
                        }

                    HStack {
                        Button {
                            runProductSearch()
                        } label: {
                            if isSearchingCatalog {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Search Catalog")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(productQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || isSearchingCatalog)
                        Spacer()
                    }

                    if isSearchingCatalog {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Searching catalog...")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if let searchError, !searchError.isEmpty {
                        Text(searchError)
                            .font(.footnote)
                            .foregroundStyle(ThistleTheme.warning)
                    } else if !hasSubmittedProductSearch, !productQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Press Search Catalog (or return) to run product lookup.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if hasSubmittedProductSearch, !productQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, filteredMealBuilderProducts.isEmpty {
                        Text("No products yet. Try a broader query.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Searches both your local items and online catalog. Long-press a product row to preview full details.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button("Scan To Search") {
                            showingBarcodeScanner = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.footnote)
                        .disabled(!DataScannerViewController.isSupported || !DataScannerViewController.isAvailable)

                        Button("Add Ingredient Manually") {
                            showingManualIngredientSheet = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.footnote)
                    }
                }

                if !selectedProducts.isEmpty {
                    Section("Selected Items") {
                        ForEach(selectedProducts) { product in
                            productRow(product)
                        }
                    }
                }

                if shouldShowRecentSuggestions && !recentSuggestedProducts.isEmpty {
                    Section("Recent Ingredients") {
                        ForEach(recentSuggestedProducts) { product in
                            productRow(product)
                        }
                    }
                }

                Section("Products") {
                    ForEach(filteredMealBuilderProducts) { product in
                        productRow(product)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThistleTheme.canvas)
            .thistleNavigationTitle(existingMeal == nil ? "New Meal" : "Edit Meal")
            .onChange(of: productQuery) { _, _ in
                hasSubmittedProductSearch = false
                searchTask?.cancel()
                isSearchingCatalog = false
            }
            .onAppear {
                hydrateFromExistingMealIfNeeded()
                rebuildKnownProducts()
            }
            .onDisappear {
                searchTask?.cancel()
                searchTask = nil
            }
            .onChange(of: scannedBarcode) { _, newValue in
                guard let newValue else { return }
                Task {
                    await handleScannedBarcode(newValue)
                }
            }
            .sheet(item: $previewProduct) { product in
                NavigationStack {
                    ProductDetailView(product: product)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingManualIngredientSheet, onDismiss: {
                rebuildKnownProducts()
            }) {
                ProductEntrySheet(
                    existingProduct: nil,
                    defaultQuery: productQuery,
                    allowLinkMode: false
                )
            }
            .sheet(isPresented: $showingBarcodeScanner) {
                NavigationStack {
                    Group {
                        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                            BarcodeScannerView(scannedCode: $scannedBarcode)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .padding()
                        } else {
                            Text("Barcode scanning requires a supported physical device.")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                    }
                    .navigationTitle("Scan Ingredient")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showingBarcodeScanner = false
                            }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let existingMeal {
                            store.updateMeal(
                                mealID: existingMeal.id,
                                name: name.isEmpty ? "Custom Meal" : name,
                                selections: servingsByProduct,
                                availableProducts: allKnownProducts
                            )
                        } else {
                            store.saveMeal(
                                name: name.isEmpty ? "Custom Meal" : name,
                                selections: servingsByProduct,
                                availableProducts: allKnownProducts
                            )
                        }
                        dismiss()
                    }
                    .disabled(selectedProducts.isEmpty)
                }
            }
        }
    }

    private func runProductSearch() {
        let trimmed = productQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        hasSubmittedProductSearch = true
        scheduleCatalogSearch(for: trimmed)
    }

    @MainActor
    private func handleScannedBarcode(_ barcode: String) async {
        await store.lookupBarcode(barcode)
        defer { scannedBarcode = nil }

        if let resolved = store.barcodeLookupResult ?? store.productForBarcode(barcode) {
            remoteSearchResults = deduplicatedProducts([resolved] + remoteSearchResults)
            rebuildKnownProducts()
            productQuery = resolved.name
            hasSubmittedProductSearch = true
            searchError = nil
            showingBarcodeScanner = false
        } else {
            hasSubmittedProductSearch = true
            searchError = "No product found for scanned barcode."
        }
    }

    private var allKnownProducts: [Product] {
        deduplicatedProducts(knownProducts + Array(selectedProductCache.values))
    }

    private var selectedProducts: [Product] {
        let selectedIDs = servingsByProduct
            .filter { $0.value > 0 }
            .map(\.key)

        return selectedIDs
            .compactMap { productID in
                allKnownProducts.first(where: { $0.id == productID })
                    ?? selectedProductCache[productID]
                    ?? store.product(withID: productID)
            }
            .sorted { lhs, rhs in
                let lhsServings = servingsByProduct[lhs.id, default: 0]
                let rhsServings = servingsByProduct[rhs.id, default: 0]
                if lhsServings == rhsServings {
                    return lhs.name < rhs.name
                }
                return lhsServings > rhsServings
            }
    }

    private var recentSuggestedProducts: [Product] {
        guard shouldShowRecentSuggestions else { return [] }

        // Use already-cached local knownProducts instead of re-sorting store.mealBuilderProducts
        // on every keystroke, which can cause visible typing lag.
        let prioritized = deduplicatedProducts(store.favoriteProducts + store.recentHistoryProducts + knownProducts)
            .filter { servingsByProduct[$0.id, default: 0] <= 0 }
            .sorted { lhs, rhs in
                let lhsFavorite = store.isFavorite(lhs) ? 1 : 0
                let rhsFavorite = store.isFavorite(rhs) ? 1 : 0
                if lhsFavorite != rhsFavorite {
                    return lhsFavorite > rhsFavorite
                }
                let lhsUsage = store.usageCounts[lhs.id, default: 0]
                let rhsUsage = store.usageCounts[rhs.id, default: 0]
                if lhsUsage == rhsUsage {
                    return lhs.lastUpdatedAt > rhs.lastUpdatedAt
                }
                return lhsUsage > rhsUsage
            }
        return Array(prioritized.prefix(10))
    }

    private var shouldShowRecentSuggestions: Bool {
        !hasSubmittedProductSearch && productQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredMealBuilderProducts: [Product] {
        if !hasSubmittedProductSearch {
            return []
        }
        let combined = allKnownProducts
        let trimmed = activeFilterQuery
        guard !trimmed.isEmpty else {
            return []
        }

        let queryTerms = normalizedTerms(from: trimmed)
        let ingredientIntent = isIngredientIntent(query: trimmed)
        return combined
            .filter { product in
                let haystack = "\(product.brand) \(product.name) \(product.ingredients.joined(separator: " "))".lowercased()
                let haystackTerms = Set(normalizedTerms(from: haystack))
                return queryTerms.allSatisfy { term in
                    haystack.contains(term) || haystackTerms.contains(where: { isFuzzyTokenMatch(query: term, candidate: $0) })
                }
            }
            .filter { servingsByProduct[$0.id, default: 0] <= 0 }
            .sorted { lhs, rhs in
                rankedScore(for: lhs, query: trimmed, ingredientIntent: ingredientIntent) > rankedScore(for: rhs, query: trimmed, ingredientIntent: ingredientIntent)
            }
    }

    private var activeFilterQuery: String {
        guard hasSubmittedProductSearch else { return "" }
        return productQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func productRow(_ product: Product) -> some View {
        let productAnalysis = store.analysis(for: product)
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 8) {
                    Text(product.name)
                    miniStatusBadge(rating: productAnalysis.rating)
                }
                Text(product.servingDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !product.hasIngredientDetails {
                    Text("Missing ingredients")
                        .font(.caption2)
                        .foregroundStyle(ThistleTheme.warning)
                }
                if isSemanticFallback(product) {
                    Text("Best semantic match")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ThistleTheme.blossomPurple)
                }
            }
            Spacer()
            Stepper(
                "\(servingsByProduct[product.id, default: 0].formatted())",
                value: binding(for: product),
                in: 0...6,
                step: 0.5
            )
            .frame(width: 140)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.45) {
            previewProduct = product
        }
    }

    private func scheduleCatalogSearch(for query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await searchCatalog(query: trimmed)
        }
    }

    @MainActor
    private func searchCatalog(query: String) async {
        isSearchingCatalog = true
        defer { isSearchingCatalog = false }
        do {
            let ingredientIntent = isIngredientIntent(query: query)
            let results = try await catalogService.searchProducts(matching: query)
            var combinedResults = results

            if ingredientIntent {
                async let rawResultsTask = catalogService.searchProducts(matching: "\(query) raw")
                async let plainResultsTask = catalogService.searchProducts(matching: "\(query) plain")
                let rawResults = (try? await rawResultsTask) ?? []
                let plainResults = (try? await plainResultsTask) ?? []
                combinedResults = deduplicatedProducts(results + rawResults + plainResults)
            }

            remoteSearchResults = combinedResults
            semanticFallbackProduct = nil

            let hasStrongIngredientCandidate = combinedResults.contains { product in
                ingredientSemanticScore(for: product, query: query) >= 70
            }

            if combinedResults.isEmpty || (ingredientIntent && !hasStrongIngredientCandidate) {
                let semantic: Product?
                do {
                    semantic = try await deepSearchService.deepSearchProduct(matching: query)
                } catch {
                    semantic = nil
                }
                semanticFallbackProduct = validatedSemanticFallback(
                    semantic,
                    query: query,
                    existing: store.mealBuilderProducts + combinedResults
                )
            }
            rebuildKnownProducts()
            searchError = nil
        } catch {
            remoteSearchResults = []
            semanticFallbackProduct = nil
            rebuildKnownProducts()
            searchError = "Catalog search failed. Showing local products only."
        }
    }

    private func binding(for product: Product) -> Binding<Double> {
        Binding(
            get: { servingsByProduct[product.id, default: 0] },
            set: { newValue in
                let previous = servingsByProduct[product.id, default: 0]
                var adjusted = newValue

                // First add defaults to 1.0 servings, then uses +/- 0.5 changes.
                if previous <= 0, newValue > 0 {
                    adjusted = max(1.0, newValue)
                }

                if adjusted <= 0 {
                    servingsByProduct[product.id] = nil
                } else {
                    servingsByProduct[product.id] = adjusted
                    selectedProductCache[product.id] = product
                }
            }
        )
    }

    private func deduplicatedProducts(_ products: [Product]) -> [Product] {
        var bestByKey: [String: Product] = [:]
        for product in products {
            let key = product.canonicalLookupKey
            if let existing = bestByKey[key] {
                bestByKey[key] = product.dataCompletenessScore >= existing.dataCompletenessScore ? product : existing
            } else {
                bestByKey[key] = product
            }
        }
        return Array(bestByKey.values)
            .sorted { lhs, rhs in
                let lhsScore = lhs.dataCompletenessScore + (store.usageCounts[lhs.id, default: 0] * 2)
                let rhsScore = rhs.dataCompletenessScore + (store.usageCounts[rhs.id, default: 0] * 2)
                if lhsScore == rhsScore { return lhs.name < rhs.name }
                return lhsScore > rhsScore
            }
    }

    private func normalizedTerms(from text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private func rankedScore(for product: Product, query: String, ingredientIntent: Bool) -> Int {
        let haystack = "\(product.brand) \(product.name)".lowercased()
        let terms = normalizedTerms(from: query)
        let termMatches = terms.reduce(into: 0) { partial, term in
            if haystack.contains(term) { partial += 1 }
        }
        let localUsageBoost = store.usageCounts[product.id, default: 0] * 2
        let semanticBoost = isSemanticFallback(product) ? 14 : 0
        let ingredientBoost = ingredientIntent ? ingredientSemanticScore(for: product, query: query) : 0
        return (termMatches * 20) + (product.dataCompletenessScore * 8) + localUsageBoost + semanticBoost + ingredientBoost
    }

    private func isFuzzyTokenMatch(query: String, candidate: String) -> Bool {
        let lengthGap = abs(query.count - candidate.count)
        if lengthGap > 2 { return false }
        if query == candidate { return true }

        let lhs = Array(query)
        let rhs = Array(candidate)
        var previous = Array(0...rhs.count)
        for (i, lhsChar) in lhs.enumerated() {
            var current = [i + 1]
            for (j, rhsChar) in rhs.enumerated() {
                let insert = current[j] + 1
                let delete = previous[j + 1] + 1
                let substitute = previous[j] + (lhsChar == rhsChar ? 0 : 1)
                current.append(min(insert, delete, substitute))
            }
            previous = current
        }
        let distance = previous[rhs.count]
        return query.count <= 5 ? distance <= 1 : distance <= 2
    }

    private func hydrateFromExistingMealIfNeeded() {
        guard !didHydrateExistingMeal else { return }
        defer { didHydrateExistingMeal = true }
        guard let existingMeal else { return }
        name = existingMeal.name
        for component in existingMeal.components {
            servingsByProduct[component.product.id] = component.servings
            selectedProductCache[component.product.id] = component.product
        }
        rebuildKnownProducts()
    }

    private func validatedSemanticFallback(_ candidate: Product?, query: String, existing: [Product]) -> Product? {
        guard var candidate else { return nil }
        let normalizedQueryTerms = Set(normalizedTerms(from: query))
        guard !normalizedQueryTerms.isEmpty else { return nil }

        let candidateTerms = Set(normalizedTerms(from: "\(candidate.brand) \(candidate.name)"))
        let overlap = normalizedQueryTerms.intersection(candidateTerms).count
        guard overlap > 0 else { return nil }
        guard candidate.hasMeaningfulNutrition || candidate.hasIngredientDetails else { return nil }

        let duplicate = existing.contains { existingProduct in
            existingProduct.canonicalLookupKey == candidate.canonicalLookupKey
                || normalizedTerms(from: existingProduct.name).joined(separator: " ") == normalizedTerms(from: candidate.name).joined(separator: " ")
        }
        guard !duplicate else { return nil }

        candidate.lastUpdatedAt = .now
        return candidate
    }

    private func isSemanticFallback(_ product: Product) -> Bool {
        guard let semanticFallbackProduct else { return false }
        return semanticFallbackProduct.canonicalLookupKey == product.canonicalLookupKey
    }

    private func isIngredientIntent(query: String) -> Bool {
        let terms = normalizedTerms(from: query)
        guard !terms.isEmpty, terms.count <= 2 else { return false }
        let dishTerms: Set<String> = [
            "salad", "soup", "pizza", "sandwich", "tortelloni", "quiche", "lasagna",
            "bowl", "meal", "wrap", "pasta", "dish", "recipe", "frozen", "prepared"
        ]
        return terms.allSatisfy { !dishTerms.contains($0) }
    }

    private func ingredientSemanticScore(for product: Product, query: String) -> Int {
        let normalizedName = normalizeComparableText(product.name)
        let queryTerms = Set(normalizedTerms(from: query))
        let nameTerms = Set(normalizedTerms(from: product.name))

        var score = 0
        if normalizedName == normalizeComparableText(query) {
            score += 120
        } else if normalizedName.hasPrefix(normalizeComparableText(query)) {
            score += 70
        }

        let overlap = queryTerms.intersection(nameTerms).count
        score += overlap * 18

        if overlap == queryTerms.count, !queryTerms.isEmpty {
            score += 30
        }

        // Prefer simple ingredient entries over prepared dishes for ingredient intent queries.
        let dishSignals = [
            "tortelloni", "quiche", "pizza", "salad", "meal", "prepared", "frozen",
            "lasagna", "burrito", "sandwich", "soup", "dhal", "curry", "ricotta", "feta"
        ]
        for signal in dishSignals where normalizedName.contains(signal) {
            score -= 35
        }

        if product.source == .usda {
            score += 20
        }

        return score
    }

    private func normalizeComparableText(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rebuildKnownProducts() {
        knownProducts = deduplicatedProducts(
            store.mealBuilderProducts
            + remoteSearchResults
            + (semanticFallbackProduct.map { [$0] } ?? [])
            + (existingMeal?.components.map(\.product) ?? [])
        )
    }

    private func miniStatusBadge(rating: ComplianceRating) -> some View {
        Text(rating.title.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundStyle(rating.color)
            .background(rating.color.opacity(0.16), in: Capsule())
    }
}
