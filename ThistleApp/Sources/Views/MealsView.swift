import SwiftUI

struct MealsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingBuilder = false

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
                }
            }
            .padding()
        }
        .background(ThistleTheme.canvas.ignoresSafeArea())
        .thistleNavigationTitle("Meals")
        .sheet(isPresented: $showingBuilder) {
            MealBuilderView()
        }
    }

    private func mealCard(_ meal: SavedMeal) -> some View {
        let analysis = store.analysis(for: meal)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meal.name)
                        .font(.headline)
                    Text(meal.components.map { "\($0.servings.formatted())x \($0.product.name)" }.joined(separator: " • "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RatingBadge(rating: analysis.rating)
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
}

struct MealBuilderView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var productQuery = ""
    @State private var servingsByProduct: [String: Double] = [:]
    @State private var remoteSearchResults: [Product] = []
    @State private var isSearchingCatalog = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    private let catalogService: ProductCatalogServing = ProductCatalogService()

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
                    } else if !productQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, filteredMealBuilderProducts.isEmpty {
                        Text("No products yet. Try a broader query.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Searches both your local items and online catalog.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Products") {
                    ForEach(filteredMealBuilderProducts) { product in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(product.name)
                                Text(product.servingDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Stepper(
                                "\(servingsByProduct[product.id, default: 0].formatted())",
                                value: binding(for: product.id),
                                in: 0...6,
                                step: 0.5
                            )
                            .frame(width: 140)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThistleTheme.canvas)
            .thistleNavigationTitle("New Meal")
            .onChange(of: productQuery) { _, newValue in
                scheduleCatalogSearch(for: newValue)
            }
            .onDisappear {
                searchTask?.cancel()
                searchTask = nil
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveMeal(name: name.isEmpty ? "Custom Meal" : name, selections: servingsByProduct)
                        dismiss()
                    }
                }
            }
        }
    }

    private var filteredMealBuilderProducts: [Product] {
        let combined = deduplicatedProducts(store.mealBuilderProducts + remoteSearchResults)
        let trimmed = productQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return combined
        }

        let queryTerms = normalizedTerms(from: trimmed)
        return combined
            .filter { product in
                let haystack = "\(product.brand) \(product.name) \(product.ingredients.joined(separator: " "))".lowercased()
                let haystackTerms = Set(normalizedTerms(from: haystack))
                return queryTerms.allSatisfy { term in
                    haystack.contains(term) || haystackTerms.contains(where: { isFuzzyTokenMatch(query: term, candidate: $0) })
                }
            }
            .sorted { lhs, rhs in
                rankedScore(for: lhs, query: trimmed) > rankedScore(for: rhs, query: trimmed)
            }
    }

    private func scheduleCatalogSearch(for query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            remoteSearchResults = []
            searchError = nil
            isSearchingCatalog = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await searchCatalog(query: trimmed)
        }
    }

    @MainActor
    private func searchCatalog(query: String) async {
        isSearchingCatalog = true
        defer { isSearchingCatalog = false }
        do {
            let results = try await catalogService.searchProducts(matching: query)
            remoteSearchResults = results
            searchError = nil
        } catch {
            remoteSearchResults = []
            searchError = "Catalog search failed. Showing local products only."
        }
    }

    private func binding(for productID: String) -> Binding<Double> {
        Binding(
            get: { servingsByProduct[productID, default: 0] },
            set: { servingsByProduct[productID] = $0 }
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

    private func rankedScore(for product: Product, query: String) -> Int {
        let haystack = "\(product.brand) \(product.name)".lowercased()
        let terms = normalizedTerms(from: query)
        let termMatches = terms.reduce(into: 0) { partial, term in
            if haystack.contains(term) { partial += 1 }
        }
        let localUsageBoost = store.usageCounts[product.id, default: 0] * 2
        return (termMatches * 20) + (product.dataCompletenessScore * 8) + localUsageBoost
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
}
