import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingAddProductSheet = false
    @State private var showingManualProductSheet = false
    @State private var searchResultLimit = 20
    @State private var recentHistoryLimit = 4
    @State private var favoritesLimit = 4

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                filters
                searchActions

                if store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.favoriteProducts.isEmpty {
                    favoritesSection
                }

                if store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.recentHistoryProducts.isEmpty {
                    recentHistorySection
                }

                if shouldShowCommittedResults, !store.matchingMeals.isEmpty {
                    mealsSection
                }

                if store.isSearching {
                    ProgressView("Searching online catalog...")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if store.isDeepSearching {
                    ProgressView("Running deep search...")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let searchError = store.searchError {
                    Text(searchError)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if store.hasSubmittedSearch && !hasAnySubmittedProductSection && !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    noResultsActions
                }

                if store.isDeepSearching && !store.deepSearchDebugLog.isEmpty {
                    debugSection
                }

                if shouldShowCommittedResults {
                    committedResultSections
                }
            }
            .padding()
        }
        .background(ThistleTheme.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Thistle")
                    .font(brandTitleFont)
                    .tracking(0.2)
                    .foregroundStyle(ThistleTheme.wordmarkGradient)
                    .shadow(color: ThistleTheme.blossomPurple.opacity(0.1), radius: 2, y: 1)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .searchable(text: $store.query, prompt: "Products, brands, ingredients")
        .onSubmit(of: .search) {
            Task { await store.performSearch() }
        }
        .onChange(of: store.query) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.clearSearch()
                searchResultLimit = 20
                recentHistoryLimit = 4
                favoritesLimit = 4
            } else {
                store.hasSubmittedSearch = false
            }
        }
        .sheet(isPresented: $showingAddProductSheet) {
            ProductEntrySheet(
                existingProduct: nil,
                defaultQuery: store.query,
                allowLinkMode: true
            )
        }
        .sheet(isPresented: $showingManualProductSheet) {
            ProductEntrySheet(
                existingProduct: nil,
                defaultQuery: store.query,
                allowLinkMode: false
            )
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Diet", selection: $store.selectedDiet) {
                ForEach(DietProfile.allCases) { diet in
                    Text(diet.rawValue).tag(diet)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Picker("Store", selection: $store.selectedStoreFilter) {
                    ForEach(store.availableStores, id: \.self) { storeName in
                        Text(storeName).tag(storeName)
                    }
                }
                .pickerStyle(.menu)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                filterToggle(title: "Hide Red", isOn: $store.onlyShowCompatible)
                filterToggle(title: "Hide Caution", isOn: $store.hideCautionOrIncomplete)
            }
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var shouldShowCommittedResults: Bool {
        let trimmed = store.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && store.hasSubmittedSearch
    }

    private var hasAnySubmittedProductSection: Bool {
        !submittedFavoriteMatches.isEmpty || !submittedRecentMatches.isEmpty || !visibleSearchResults.isEmpty
    }

    private var committedResultSections: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !submittedFavoriteMatches.isEmpty {
                Text("Favorites")
                    .font(.headline)
                ForEach(submittedFavoriteMatches) { product in
                    productSearchCard(for: product)
                }
            }

            if !submittedRecentMatches.isEmpty {
                Text("Recent History")
                    .font(.headline)
                ForEach(submittedRecentMatches) { product in
                    productSearchCard(for: product)
                }
            }

            if !visibleSearchResults.isEmpty {
                Text("Search Results")
                    .font(.headline)
                ForEach(visibleSearchResults) { product in
                    productSearchCard(for: product)
                }

                if remainingSearchResults.count > searchResultLimit {
                    Button("Show More Results") {
                        searchResultLimit += 20
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var submittedFavoriteMatches: [Product] {
        Array(
            store.favoriteProducts
                .filter { submittedResultIDs.contains($0.id) }
                .prefix(6)
        )
    }

    private var submittedRecentMatches: [Product] {
        let favoriteIDs = Set(submittedFavoriteMatches.map(\.id))
        return Array(
            store.recentHistoryProducts
                .filter { !favoriteIDs.contains($0.id) && submittedResultIDs.contains($0.id) }
                .prefix(6)
        )
    }

    private var submittedResultIDs: Set<String> {
        Set(store.searchResults.map(\.id))
    }

    private var remainingSearchResults: [Product] {
        let pinnedIDs = Set(submittedFavoriteMatches.map(\.id) + submittedRecentMatches.map(\.id))
        return store.searchResults.filter { !pinnedIDs.contains($0.id) }
    }

    private var visibleSearchResults: [Product] {
        Array(remainingSearchResults.prefix(searchResultLimit))
    }

    private var searchActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await store.performSearch() }
                } label: {
                    if store.isSearching {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Search Online Catalog")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || store.isSearching)

                if store.hasSubmittedSearch {
                    Text("\(store.searchResults.count) foods")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Button("BETA: Deep Search") {
                Task { await store.runManualDeepSearchForCurrentQuery() }
            }
            .buttonStyle(.bordered)
            .disabled(store.query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || store.isDeepSearching)

            Button("Add Manually") {
                showingManualProductSheet = true
            }
            .buttonStyle(.bordered)
        }
    }

    private func filterToggle(title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
            Text(title)
                .font(.subheadline)
        }
    }

    private var recentHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent History")
                .font(.headline)

            ForEach(store.recentHistoryProducts.prefix(recentHistoryLimit)) { product in
                productSearchCard(for: product)
            }

            if store.recentHistoryProducts.count > recentHistoryLimit {
                Button("Show More Recent") {
                    recentHistoryLimit += 4
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorites")
                .font(.headline)

            ForEach(store.favoriteProducts.prefix(favoritesLimit)) { product in
                productSearchCard(for: product)
            }

            if store.favoriteProducts.count > favoritesLimit {
                Button("Show More Favorites") {
                    favoritesLimit += 4
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func productSearchCard(for product: Product) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                ProductDetailView(product: product)
            } label: {
                ProductCard(product: product, analysis: store.analysis(for: product))
            }
            .buttonStyle(.plain)
        }
    }

    private var noResultsActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasAttemptedDeepSearchForCurrentQuery {
                Button("Add Product (Link)") {
                    showingAddProductSheet = true
                }
                .buttonStyle(.borderedProminent)

                Button("Try Deep Search Again") {
                    Task { await store.runManualDeepSearchForCurrentQuery() }
                }
                .buttonStyle(.bordered)
                .disabled(store.query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || store.isDeepSearching)
            } else {
                Text("No good matches yet. Try BETA: Deep Search above, or add manually.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasAttemptedDeepSearchForCurrentQuery: Bool {
        let trimmedQuery = store.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return false }
        return store.deepSearchDebugLog.contains { entry in
            entry.localizedCaseInsensitiveContains("Starting manual deep search for query: \(trimmedQuery)")
                || entry.localizedCaseInsensitiveContains("Used cached deep search result for query: \(trimmedQuery)")
                || entry.localizedCaseInsensitiveContains("Used cached deep search miss for query: \(trimmedQuery)")
        }
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Deep Search Debug")
                .font(.headline)
            ForEach(Array(store.deepSearchDebugLog.enumerated()), id: \.offset) { _, entry in
                Text(entry)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var mealsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Meals")
                .font(.headline)

            ForEach(store.matchingMeals) { meal in
                let analysis = store.analysis(for: meal)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meal.name)
                                .font(.headline)
                            Text(meal.components.map(\.product.name).joined(separator: " • "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        RatingBadge(rating: analysis.rating)
                    }

                    MacroSummaryView(nutrition: meal.nutrition)

                    Button("Log Meal") {
                        store.log(meal: meal)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private var brandTitleFont: Font {
#if canImport(UIKit)
        if let fontName = firstAvailableFontName(containingAnyOf: ["bitcount ink", "bitcount"]) {
            return .custom(fontName, size: 35)
        }
        if let fontName = firstAvailableFontName(containingAnyOf: ["nabla"]) {
            return .custom(fontName, size: 35)
        }
        if let fontName = firstAvailableFontName(containingAnyOf: ["unica one", "unicaone"]) {
            return .custom(fontName, size: 35)
        }
        if let fontName = firstAvailableFontName(containingAnyOf: ["sora"]) {
            return .custom(fontName, size: 35)
        }
        if let fontName = firstAvailableFontName(containingAnyOf: ["quicksand"]) {
            return .custom(fontName, size: 35)
        }
#endif
        return .system(size: 34, weight: .semibold, design: .rounded)
    }

#if canImport(UIKit)
    private func firstAvailableFontName(containingAnyOf terms: [String]) -> String? {
        let allFontNames = UIFont.familyNames.flatMap { family in
            UIFont.fontNames(forFamilyName: family)
        }

        for term in terms {
            if let match = allFontNames.first(where: { $0.lowercased().contains(term) }) {
                return match
            }
        }
        return nil
    }
#endif
}

struct AddProductToMealSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let product: Product
    @State private var servings: Double
    @State private var newMealName = ""

    init(product: Product, servings: Double = 1) {
        self.product = product
        _servings = State(initialValue: servings)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Product") {
                    Text(product.name)
                    Text(product.brand)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Servings To Add") {
                    Stepper(
                        "\(servings.formatted(.number.precision(.fractionLength(0...2))))",
                        value: $servings,
                        in: 0.5...12,
                        step: 0.5
                    )
                }

                Section("Add To Existing Meal") {
                    if store.meals.isEmpty {
                        Text("No saved meals yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.meals) { meal in
                            Button(meal.name) {
                                store.addProduct(product, servings: servings, toMealID: meal.id)
                                store.selectedTab = .meals
                                dismiss()
                            }
                        }
                    }
                }

                Section("Create New Meal") {
                    TextField("Meal name", text: $newMealName)
                    Button("Create Meal + Add Product") {
                        _ = store.createMeal(name: newMealName, with: product, servings: servings)
                        store.selectedTab = .meals
                        dismiss()
                    }
                }
            }
            .navigationTitle("Add To Meal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}
