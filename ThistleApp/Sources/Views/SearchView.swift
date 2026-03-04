import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                filters

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
        .navigationTitle("Search Foods")
        .searchable(text: $store.query, prompt: "Products, brands, ingredients")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diet-aware product search")
                .font(.largeTitle.weight(.bold))
            Text("Search foods, review macros, and see exactly which ingredients help or hurt your current diet.")
                .foregroundStyle(.secondary)
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
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
