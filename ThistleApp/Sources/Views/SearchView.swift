import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SearchView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                filters
                searchActions

                if store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.recentHistoryProducts.isEmpty {
                    recentHistorySection
                }

                if !store.matchingMeals.isEmpty {
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

                if store.hasSubmittedSearch && store.searchResults.isEmpty && !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    deepSearchButton
                }

                if store.isDeepSearching && !store.deepSearchDebugLog.isEmpty {
                    debugSection
                }

                ForEach(store.searchResults) { product in
                    NavigationLink {
                        ProductDetailView(product: product)
                    } label: {
                        ProductCard(product: product, analysis: store.analysis(for: product))
                    }
                    .buttonStyle(.plain)
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
            }
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

    private var searchActions: some View {
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

            ForEach(store.recentHistoryProducts) { product in
                NavigationLink {
                    ProductDetailView(product: product)
                } label: {
                    ProductCard(product: product, analysis: store.analysis(for: product))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var deepSearchButton: some View {
        Button("BETA: Find With Deep Search") {
            Task { await store.runManualDeepSearchForCurrentQuery() }
        }
        .buttonStyle(.bordered)
        .disabled(store.query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || store.isDeepSearching)
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
