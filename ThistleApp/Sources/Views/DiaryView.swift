import SwiftUI
import Foundation

struct DiaryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editingEntry: LoggedFood?
    @State private var showingContributionMetric: GoalMetric?
    @State private var draftServingAmount = 1.0
    @State private var draftServingInput = "1"
    @State private var draftServingError: String?

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
                        diaryEntry(entry)
                    }
                }
            }
            .padding()
        }
        .background(ThistleTheme.canvas.ignoresSafeArea())
        .thistleNavigationTitle("Diary")
        .sheet(item: $editingEntry) { entry in
            NavigationStack {
                Form {
                    Section("Serving Size") {
                        Stepper(value: $draftServingAmount, in: 0.1...12, step: 0.5) {
                            Text("\(draftServingAmount.formatted(.number.precision(.fractionLength(0...1)))) x \(entry.baseServingDescription ?? "serving")")
                        }
                        .onChange(of: draftServingAmount) { _, newValue in
                            draftServingInput = newValue.formatted(.number.precision(.fractionLength(0...2)))
                            draftServingError = nil
                        }

                        HStack(spacing: 8) {
                            TextField("Servings", text: $draftServingInput)
                                .keyboardType(.numbersAndPunctuation)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    _ = applyDraftServingInput()
                                }
                            Button("Set") {
                                _ = applyDraftServingInput()
                            }
                            .buttonStyle(.bordered)
                        }

                        Text("Use decimals or fractions, e.g. 0.1 or 1/2.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let draftServingError {
                            Text(draftServingError)
                                .font(.caption)
                                .foregroundStyle(ThistleTheme.warning)
                        }
                    }
                }
                .navigationTitle("Edit Entry")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            editingEntry = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            guard applyDraftServingInput() else { return }
                            store.updateLoggedFoodServing(entryID: entry.id, servings: draftServingAmount)
                            editingEntry = nil
                        }
                    }
                }
            }
        }
        .sheet(item: $showingContributionMetric) { metric in
            NutrientContributionSheet(
                metric: metric,
                entries: store.loggedFoods,
                consumedTotal: consumedAmount(for: metric),
                goalTotal: goalAmount(for: metric)
            )
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Goal Progress")
                .font(.headline)

            MacroSummaryView(nutrition: store.todayNutrition)

            progressRow(metric: .calories, current: Double(store.todayNutrition.calories), goal: Double(store.goals.calories))
            progressRow(metric: .protein, current: store.todayNutrition.protein, goal: store.goals.protein)
            progressRow(metric: .carbs, current: store.todayNutrition.carbs, goal: store.goals.carbs)
            progressRow(metric: .fat, current: store.todayNutrition.fat, goal: store.goals.fat)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Other Nutrition Goals")
                    .font(.subheadline.weight(.semibold))
                progressRow(metric: .fiber, current: store.todayNutrition.fiber, goal: store.goals.fiber)
            }
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
                    Text(roundedNumericText(in: entry.servingText))
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

    @ViewBuilder
    private func diaryEntry(_ entry: LoggedFood) -> some View {
        if let product = linkedProduct(for: entry) {
            NavigationLink {
                ProductDetailView(product: product)
            } label: {
                diaryCard(entry: entry)
            }
            .buttonStyle(.plain)
            .contextMenu {
                diaryContextMenu(entry: entry)
            }
        } else {
            diaryCard(entry: entry)
                .contextMenu {
                    diaryContextMenu(entry: entry)
                }
        }
    }

    @ViewBuilder
    private func diaryContextMenu(entry: LoggedFood) -> some View {
        if canEditServing(for: entry) {
            Button("Edit Serving Size") {
                draftServingAmount = max(entry.loggedServings ?? 1, 0.5)
                draftServingInput = draftServingAmount.formatted(.number.precision(.fractionLength(0...2)))
                draftServingError = nil
                editingEntry = entry
            }
        }
        Button(role: .destructive) {
            store.deleteLoggedFood(entryID: entry.id)
        } label: {
            Text("Delete Entry")
        }
    }

    private func linkedProduct(for entry: LoggedFood) -> Product? {
        if let primaryID = entry.sourceProductID, let product = store.product(withID: primaryID) {
            return product
        }
        if entry.sourceProductIDs.count == 1, let fallbackID = entry.sourceProductIDs.first {
            return store.product(withID: fallbackID)
        }
        return nil
    }

    private func canEditServing(for entry: LoggedFood) -> Bool {
        linkedProduct(for: entry) != nil || entry.loggedServings != nil
    }

    @discardableResult
    private func applyDraftServingInput() -> Bool {
        guard let parsed = parseServingAmount(draftServingInput) else {
            draftServingError = "Enter a valid serving amount like 0.1 or 1/2."
            return false
        }
        draftServingAmount = min(max(parsed, 0.1), 12)
        draftServingInput = draftServingAmount.formatted(.number.precision(.fractionLength(0...2)))
        draftServingError = nil
        return true
    }

    private func parseServingAmount(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let decimal = Double(trimmed), decimal > 0 {
            return decimal
        }

        if trimmed.contains("/") {
            let parts = trimmed.split(separator: " ").map(String.init)
            if parts.count == 1, let fraction = parseFraction(parts[0]) {
                return fraction
            }
            if parts.count == 2, let whole = Double(parts[0]), let fraction = parseFraction(parts[1]) {
                let value = whole + fraction
                return value > 0 ? value : nil
            }
        }
        return nil
    }

    private func parseFraction(_ token: String) -> Double? {
        let pieces = token.split(separator: "/")
        guard pieces.count == 2,
              let numerator = Double(pieces[0]),
              let denominator = Double(pieces[1]),
              denominator != 0 else {
            return nil
        }
        let value = numerator / denominator
        return value > 0 ? value : nil
    }

    private func roundedNumericText(in text: String) -> String {
        let pattern = #"\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let originalRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: originalRange).reversed()
        var result = text
        for match in matches {
            guard let sourceRange = Range(match.range, in: text),
                  let numericValue = Double(text[sourceRange]) else {
                continue
            }
            let replacement = numericValue.formatted(.number.precision(.fractionLength(0...2)))
            if let resultRange = Range(match.range, in: result) {
                result.replaceSubrange(resultRange, with: replacement)
            }
        }
        return result
    }

    private func progressRow(metric: GoalMetric, current: Double, goal: Double) -> some View {
        let progress = min(current / max(goal, 1), 1.0)
        return Button {
            showingContributionMetric = metric
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(metric.title)
                    Spacer()
                    Text("\(metric.formatted(current)) / \(metric.formatted(goal))")
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
                    .tint(progress >= 1 ? ThistleTheme.primaryGreen : .accentColor)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("Show \(metric.title) contributors")
    }

    private func consumedAmount(for metric: GoalMetric) -> Double {
        switch metric {
        case .calories: return Double(store.todayNutrition.calories)
        case .protein: return store.todayNutrition.protein
        case .carbs: return store.todayNutrition.carbs
        case .fat: return store.todayNutrition.fat
        case .fiber: return store.todayNutrition.fiber
        }
    }

    private func goalAmount(for metric: GoalMetric) -> Double {
        switch metric {
        case .calories: return Double(store.goals.calories)
        case .protein: return store.goals.protein
        case .carbs: return store.goals.carbs
        case .fat: return store.goals.fat
        case .fiber: return store.goals.fiber
        }
    }
}

private enum GoalMetric: String, Identifiable {
    case calories
    case protein
    case carbs
    case fat
    case fiber

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calories: return "Calories"
        case .protein: return "Protein"
        case .carbs: return "Carbs"
        case .fat: return "Fat"
        case .fiber: return "Fiber"
        }
    }

    func value(in nutrition: NutritionFacts) -> Double {
        switch self {
        case .calories: return Double(nutrition.calories)
        case .protein: return nutrition.protein
        case .carbs: return nutrition.carbs
        case .fat: return nutrition.fat
        case .fiber: return nutrition.fiber
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .calories:
            return Int(value.rounded()).formatted()
        case .protein, .carbs, .fat, .fiber:
            return "\(value.formatted(.number.precision(.fractionLength(0...1))))g"
        }
    }
}

private struct NutrientContributionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let metric: GoalMetric
    let entries: [LoggedFood]
    let consumedTotal: Double
    let goalTotal: Double

    var body: some View {
        NavigationStack {
            List {
                Section("Progress") {
                    HStack {
                        Text("Consumed")
                        Spacer()
                        Text(metric.formatted(consumedTotal))
                    }
                    HStack {
                        Text("Goal")
                        Spacer()
                        Text(metric.formatted(goalTotal))
                    }
                    HStack {
                        Text("Completion")
                        Spacer()
                        Text("\((consumedTotal / max(goalTotal, 1) * 100).formatted(.number.precision(.fractionLength(0...1))))%")
                            .foregroundStyle(consumedTotal >= goalTotal ? ThistleTheme.primaryGreen : .secondary)
                    }
                }

                Section("Where It Came From") {
                    if contributions.isEmpty {
                        Text("No logged entries are contributing yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(contributions, id: \.entry.id) { row in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.entry.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text(row.entry.servingText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(metric.formatted(row.value))
                                        .font(.subheadline.weight(.semibold))
                                    Text("\((row.shareOfConsumed * 100).formatted(.number.precision(.fractionLength(0...1))))% of consumed")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(metric.title) Contributors")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var contributions: [(entry: LoggedFood, value: Double, shareOfConsumed: Double)] {
        let rows = entries.map { entry in
            (entry: entry, value: metric.value(in: entry.nutrition))
        }
        .filter { $0.value > 0 }
        .sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.entry.loggedAt > rhs.entry.loggedAt
            }
            return lhs.value > rhs.value
        }

        let total = max(consumedTotal, 0.0001)
        return rows.map { row in
            (entry: row.entry, value: row.value, shareOfConsumed: row.value / total)
        }
    }
}
