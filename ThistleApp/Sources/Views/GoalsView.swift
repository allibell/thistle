import SwiftUI

struct GoalsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var draftProteinPercent = 0
    @State private var draftCarbPercent = 0
    @State private var draftFatPercent = 0

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
                    color: ThistleTheme.blossomPink,
                    percent: $draftProteinPercent,
                    grams: grams(forPercent: draftProteinPercent, caloriesPerGram: 4)
                )

                macroEditor(
                    title: "Carbs",
                    color: ThistleTheme.blossomPurple,
                    percent: $draftCarbPercent,
                    grams: grams(forPercent: draftCarbPercent, caloriesPerGram: 4)
                )

                macroEditor(
                    title: "Fat",
                    color: ThistleTheme.stemGreen,
                    percent: $draftFatPercent,
                    grams: grams(forPercent: draftFatPercent, caloriesPerGram: 9)
                )

                HStack {
                    Text("Allocated")
                    Spacer()
                    Text("\(totalPercent)%")
                        .foregroundStyle(totalPercent == 100 ? ThistleTheme.primaryGreen : ThistleTheme.danger)
                }

                if totalPercent != 100 {
                    Text("Macros must total 100% before saving.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ThistleTheme.danger)
                }

                Button("Set Macro Goals") {
                    store.setMacroPercents(protein: draftProteinPercent, carbs: draftCarbPercent, fat: draftFatPercent)
                }
                .buttonStyle(.borderedProminent)
                .disabled(totalPercent != 100)
            }

            Section("Daily Targets") {
                MacroSummaryView(
                    nutrition: NutritionFacts(
                        calories: store.goals.calories,
                        protein: grams(forPercent: draftProteinPercent, caloriesPerGram: 4),
                        carbs: grams(forPercent: draftCarbPercent, caloriesPerGram: 4),
                        fat: grams(forPercent: draftFatPercent, caloriesPerGram: 9)
                    )
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThistleTheme.canvas)
        .thistleNavigationTitle("Goals")
        .onAppear(perform: syncDraftFromStore)
    }

    private var totalPercent: Int {
        draftProteinPercent + draftCarbPercent + draftFatPercent
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
        percent: Binding<Int>,
        grams: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(percent.wrappedValue)% • \(Int(grams.rounded()))g")
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(percent.wrappedValue) },
                    set: { percent.wrappedValue = Int($0.rounded()) }
                ),
                in: 0...100,
                step: 1
            )
            .tint(color)
        }
    }

    private func syncDraftFromStore() {
        draftProteinPercent = store.goals.proteinPercent
        draftCarbPercent = store.goals.carbPercent
        draftFatPercent = store.goals.fatPercent
    }

    private func grams(forPercent percent: Int, caloriesPerGram: Double) -> Double {
        let allocatedCalories = (Double(store.goals.calories) * Double(percent)) / 100
        return allocatedCalories / caloriesPerGram
    }
}
