import SwiftUI

struct DiaryView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Today")
                    .font(.largeTitle.weight(.bold))
                progressSection

                if store.loggedFoods.isEmpty {
                    emptyState
                } else {
                    ForEach(store.loggedFoods) { entry in
                        diaryCard(entry: entry)
                    }
                }
            }
            .padding()
        }
        .background(ThistleTheme.canvas.ignoresSafeArea())
        .thistleNavigationTitle("Diary")
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Goal Progress")
                .font(.headline)

            MacroSummaryView(nutrition: store.todayNutrition)

            progressRow(label: "Calories", current: Double(store.todayNutrition.calories), goal: Double(store.goals.calories))
            progressRow(label: "Protein", current: store.todayNutrition.protein, goal: store.goals.protein)
            progressRow(label: "Carbs", current: store.todayNutrition.carbs, goal: store.goals.carbs)
            progressRow(label: "Fat", current: store.todayNutrition.fat, goal: store.goals.fat)
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No foods logged yet")
                .font(.headline)
            Text("Search a product, scan a barcode, or log one of your saved meals.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func diaryCard(entry: LoggedFood) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.headline)
                    Text(entry.servingText)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RatingBadge(rating: entry.analysis.rating)
            }

            MacroSummaryView(nutrition: entry.nutrition)

            if !entry.analysis.flags.isEmpty {
                Text(entry.analysis.flags.map(\.ingredient).joined(separator: ", "))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(entry.analysis.rating.color)
            }
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func progressRow(label: String, current: Double, goal: Double) -> some View {
        let progress = min(current / max(goal, 1), 1.0)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(current.rounded())) / \(Int(goal.rounded()))")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .tint(progress >= 1 ? ThistleTheme.primaryGreen : .accentColor)
        }
    }
}
