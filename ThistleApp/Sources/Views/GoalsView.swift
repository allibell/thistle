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

            Section("Daily Goals") {
                Stepper("Calories: \(store.goals.calories)", value: goalsBinding(\.calories), in: 1000...4000, step: 50)
                Stepper("Protein: \(Int(store.goals.protein))g", value: goalsBinding(\.protein), in: 40...250, step: 5)
                Stepper("Carbs: \(Int(store.goals.carbs))g", value: goalsBinding(\.carbs), in: 20...350, step: 5)
                Stepper("Fat: \(Int(store.goals.fat))g", value: goalsBinding(\.fat), in: 20...200, step: 5)
            }

            Section("Why this matters") {
                Text("The selected diet controls ingredient scoring across search, scanning, meals, and diary entries. Macro goals drive progress in the diary.")
            }
        }
        .navigationTitle("Goals")
    }

    private func goalsBinding<Value>(_ keyPath: WritableKeyPath<MacroGoals, Value>) -> Binding<Value> {
        Binding(
            get: { store.goals[keyPath: keyPath] },
            set: { store.goals[keyPath: keyPath] = $0 }
        )
    }
}
