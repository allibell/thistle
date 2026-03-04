import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                filters
                searchActions

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
        .navigationTitle("Thistle")
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

                Toggle("Hide Red", isOn: $store.onlyShowCompatible)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Text("Hide Red")
                    .font(.subheadline)
            }

            HStack {
                Toggle("Hide Caution", isOn: $store.hideCautionOrIncomplete)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Text("Hide Caution")
                    .font(.subheadline)
                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
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
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }
}
