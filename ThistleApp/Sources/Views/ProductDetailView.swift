import SwiftUI

struct ProductDetailView: View {
    @EnvironmentObject private var store: AppStore
    var product: Product
    @State private var servings = 1.0

    var body: some View {
        let analysis = store.analysis(for: product)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(product.name)
                                .font(.largeTitle.weight(.bold))
                            Text(product.brand)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        RatingBadge(rating: analysis.rating)
                    }

                    Text(analysis.summary)
                        .font(.headline)
                        .foregroundStyle(analysis.rating.color)

                    Text("Available at \(product.stores.joined(separator: ", "))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    MacroSummaryView(nutrition: product.nutrition * servings)
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Serving")
                        .font(.headline)
                    Stepper(value: $servings, in: 0.5...6, step: 0.5) {
                        Text("\(servings.formatted()) x \(product.servingDescription)")
                    }
                    Button("Log Food") {
                        store.log(product: product, servings: servings)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))

                IngredientsSection(product: product, analysis: analysis)
            }
            .padding()
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}
