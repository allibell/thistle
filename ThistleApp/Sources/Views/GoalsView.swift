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
                    Text("None").tag(nil as DietProfile?)
                    ForEach(DietProfile.allCases) { diet in
                        Text(diet.rawValue).tag(Optional(diet))
                    }
                }

                Text("Choose a primary diet only when one applies to your current goals.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Ingredient Restrictions") {
                ForEach(DietaryRestriction.allCases) { restriction in
                    Toggle(isOn: restrictionBinding(restriction)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(restriction.rawValue)
                            Text(restriction.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("Checks are based on listed ingredients and cannot verify cross-contact or facility warnings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                ForEach(NutritionGoalPreset.allCases) { preset in
                    Button {
                        store.applyNutritionGoalPreset(preset)
                        showGoalsSavedConfirmation()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.rawValue)
                            Text(preset.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Stepper(
                    "Daily fiber: \(store.goals.fiber.formatted(.number.precision(.fractionLength(0...1)))) g",
                    value: goalsBinding(\.fiber),
                    in: 0...80,
                    step: 1
                )

                Stepper(
                    "Daily iron: \(store.goals.ironMg.formatted(.number.precision(.fractionLength(0...1)))) mg",
                    value: goalsBinding(\.ironMg),
                    in: 0...45,
                    step: 1
                )

                Stepper(
                    "Daily vitamin D: \(store.goals.vitaminDMcg.formatted(.number.precision(.fractionLength(0...1)))) mcg",
                    value: goalsBinding(\.vitaminDMcg),
                    in: 0...100,
                    step: 1
                )

                Stepper(
                    "Saturated fat limit: \(store.goals.saturatedFatLimit.formatted(.number.precision(.fractionLength(0...1)))) g",
                    value: goalsBinding(\.saturatedFatLimit),
                    in: 0...50,
                    step: 1
                )

                Stepper(
                    "Cholesterol limit: \(store.goals.cholesterolLimitMg.formatted(.number.precision(.fractionLength(0...0)))) mg",
                    value: goalsBinding(\.cholesterolLimitMg),
                    in: 0...500,
                    step: 10
                )

                Text("These are tracking targets and limits for personal nutrition planning. Use clinician guidance for lab-specific goals.")
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

                goalSummaryRow("Iron Goal", value: store.goals.ironMg, unit: "mg")
                goalSummaryRow("Vitamin D Goal", value: store.goals.vitaminDMcg, unit: "mcg")
                goalSummaryRow("Saturated Fat Limit", value: store.goals.saturatedFatLimit, unit: "g")
                goalSummaryRow("Cholesterol Limit", value: store.goals.cholesterolLimitMg, unit: "mg")
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

    private func restrictionBinding(_ restriction: DietaryRestriction) -> Binding<Bool> {
        Binding(
            get: { store.dietaryRestrictions.contains(restriction) },
            set: { isSelected in
                if isSelected {
                    store.dietaryRestrictions.insert(restriction)
                } else {
                    store.dietaryRestrictions.remove(restriction)
                }
            }
        )
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

    private func goalSummaryRow(_ title: String, value: Double, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                .foregroundStyle(.secondary)
        }
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
