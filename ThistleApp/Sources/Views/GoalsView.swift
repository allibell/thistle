import SwiftUI

struct GoalsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var draftProteinPercent = 0
    @State private var draftCarbPercent = 0
    @State private var draftFatPercent = 0
    @State private var didJustSaveGoals = false
    @State private var goalsSavedTask: Task<Void, Never>?

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

                HStack(spacing: 10) {
                    Button("Set Macro Goals") {
                        store.setMacroPercents(protein: draftProteinPercent, carbs: draftCarbPercent, fat: draftFatPercent)
                        showGoalsSavedConfirmation()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(totalPercent != 100)

                    if didJustSaveGoals {
                        Label("Saved!", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ThistleTheme.primaryGreen)
                            .transition(.opacity.combined(with: .scale))
                    }
                }
            }

            Section("Other Nutrition Goals") {
                Stepper(
                    "Daily fiber: \(store.goals.fiber.formatted(.number.precision(.fractionLength(0...1)))) g",
                    value: goalsBinding(\.fiber),
                    in: 0...80,
                    step: 1
                )

                Text("Fiber is tracked separately from calorie-based macro split. This section will also hold micronutrient goals like calcium and vitamin D.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Daily Targets") {
                MacroSummaryView(
                    nutrition: NutritionFacts(
                        calories: store.goals.calories,
                        protein: grams(forPercent: draftProteinPercent, caloriesPerGram: 4),
                        carbs: grams(forPercent: draftCarbPercent, caloriesPerGram: 4),
                        fat: grams(forPercent: draftFatPercent, caloriesPerGram: 9),
                        fiber: store.goals.fiber
                    )
                )

                HStack {
                    Text("Fiber Goal")
                    Spacer()
                    Text("\(store.goals.fiber.formatted(.number.precision(.fractionLength(0...1)))) g")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThistleTheme.canvas)
        .thistleNavigationTitle("Goals")
        .onAppear(perform: syncDraftFromStore)
        .onDisappear {
            goalsSavedTask?.cancel()
            goalsSavedTask = nil
        }
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

    private func showGoalsSavedConfirmation() {
        goalsSavedTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            didJustSaveGoals = true
        }

        goalsSavedTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) {
                    didJustSaveGoals = false
                }
            }
        }
    }
}
