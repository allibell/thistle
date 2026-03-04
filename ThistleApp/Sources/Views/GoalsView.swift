import SwiftUI

struct GoalsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("Diet") {
                Picker("Current diet", selection: $store.selectedDiet) {
                    ForEach(DietProfile.allCases) { diet in
                        Text(diet.rawValue).tag(diet)
                    }
                }
            }

            Section("Calories") {
                Stepper("Daily calories: \(store.goals.calories)", value: goalsBinding(\.calories), in: 1000...4000, step: 50)
            }

            Section("Macro Split") {
                macroEditor(
                    title: "Protein",
                    color: .red,
                    percent: store.goals.proteinPercent,
                    grams: store.goals.protein,
                    remainingAllowance: 100 - store.goals.carbPercent - store.goals.fatPercent
                ) { store.setMacroPercents(protein: $0, carbs: store.goals.carbPercent, fat: store.goals.fatPercent) }

                macroEditor(
                    title: "Carbs",
                    color: .blue,
                    percent: store.goals.carbPercent,
                    grams: store.goals.carbs,
                    remainingAllowance: 100 - store.goals.proteinPercent - store.goals.fatPercent
                ) { store.setMacroPercents(protein: store.goals.proteinPercent, carbs: $0, fat: store.goals.fatPercent) }

                macroEditor(
                    title: "Fat",
                    color: .orange,
                    percent: store.goals.fatPercent,
                    grams: store.goals.fat,
                    remainingAllowance: 100 - store.goals.proteinPercent - store.goals.carbPercent
                ) { store.setMacroPercents(protein: store.goals.proteinPercent, carbs: store.goals.carbPercent, fat: $0) }

                HStack {
                    Text("Assigned")
                    Spacer()
                    Text("\(store.goals.proteinPercent + store.goals.carbPercent + store.goals.fatPercent)%")
                        .foregroundStyle(totalPercent == 100 ? .green : .secondary)
                }

                if totalPercent < 100 {
                    HStack {
                        Text("Unassigned")
                        Spacer()
                        Text("\(100 - totalPercent)%")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Daily Targets") {
                MacroSummaryView(
                    nutrition: NutritionFacts(
                        calories: store.goals.calories,
                        protein: store.goals.protein,
                        carbs: store.goals.carbs,
                        fat: store.goals.fat
                    )
                )
            }
        }
        .navigationTitle("Goals")
    }

    private var totalPercent: Int {
        store.goals.proteinPercent + store.goals.carbPercent + store.goals.fatPercent
    }

    private func goalsBinding<Value>(_ keyPath: WritableKeyPath<MacroGoals, Value>) -> Binding<Value> {
        Binding(
            get: { store.goals[keyPath: keyPath] },
            set: { store.goals[keyPath: keyPath] = $0 }
        )
    }

    private func macroEditor(
        title: String,
        color: Color,
        percent: Int,
        grams: Double,
        remainingAllowance: Int,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(percent)% • \(Int(grams.rounded()))g")
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(percent) },
                    set: { onChange(min(Int($0.rounded()), max(remainingAllowance, percent))) }
                ),
                in: 0...Double(max(remainingAllowance, percent)),
                step: 1
            )
            .tint(color)
        }
    }
}
