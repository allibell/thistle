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
        .navigationTitle("Meals")
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
    @State private var servingsByProduct: [String: Double] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section("Meal Name") {
                    TextField("Whole30 Lunch Bowl", text: $name)
                }

                Section("Products") {
                    ForEach(store.mealBuilderProducts) { product in
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
            .navigationTitle("New Meal")
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

    private func binding(for productID: String) -> Binding<Double> {
        Binding(
            get: { servingsByProduct[productID, default: 0] },
            set: { servingsByProduct[productID] = $0 }
        )
    }
}
