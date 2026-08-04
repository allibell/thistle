import SwiftUI
import Foundation

struct DiaryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editingEntry: LoggedFood?
    @State private var showingContributionMetric: GoalMetric?
    @State private var selectedDate = Date.now
    @State private var showingDatePicker = false
    @State private var draftServingAmount = 1.0
    @State private var draftServingInput = "1"
    @State private var draftServingError: String?
    @State private var showingQuickLog = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Diary")
                    .font(.largeTitle.weight(.bold))
                dateNavigationSection
                Button {
                    showingQuickLog = true
                } label: {
                    Label(foodLoggerButtonTitle, systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                progressSection

                if selectedDayEntries.isEmpty {
                    emptyState
                } else {
                    ForEach(selectedDayEntries) { entry in
                        diaryEntry(entry)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(ThistleTheme.canvas.ignoresSafeArea())
        .thistleNavigationTitle("Diary")
        .sheet(isPresented: $showingQuickLog) {
            QuickLogSheet(loggedAt: selectedDate)
                .environmentObject(store)
        }
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
                entries: selectedDayEntries,
                consumedTotal: consumedAmount(for: metric),
                goalTotal: goalAmount(for: metric)
            )
        }
        .sheet(isPresented: $showingDatePicker) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        DatePicker(
                            "Diary Date",
                            selection: $selectedDate,
                            in: ...Date.now,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(.horizontal)

                        if !isViewingToday {
                            Button {
                                selectDate(.now)
                                showingDatePicker = false
                            } label: {
                                Label("Return to Today", systemImage: "arrow.uturn.backward.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.horizontal)
                        }

                        if !recentDiaryDays.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Recent Diary Days")
                                    .font(.headline)

                                ForEach(recentDiaryDays) { day in
                                    Button {
                                        selectDate(day.date)
                                        showingDatePicker = false
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(ThistleTheme.primaryGreen)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(dayTitle(for: day.date))
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.primary)
                                                Text("\(day.entryCount) \(day.entryCount == 1 ? "entry" : "entries")")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text("\(day.calories) cal")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(12)
                                        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 14))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }

                        Text("Days containing diary entries are also marked with green dots in the week strip.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    .padding(.vertical, 12)
                }
                .background(ThistleTheme.canvas.ignoresSafeArea())
                .navigationTitle("Diary History")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showingDatePicker = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: selectedDate) { _, newDate in
            selectedDate = normalizedDate(newDate)
        }
    }

    private var dateNavigationSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    moveSelectedDate(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.bold))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Previous day")

                Button {
                    showingDatePicker = true
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Text(diaryHeaderTitle)
                                .font(.headline)
                            Image(systemName: "calendar")
                                .font(.subheadline.weight(.semibold))
                        }
                        Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open diary calendar for \(diaryHeaderTitle)")

                Button {
                    moveSelectedDate(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.headline.weight(.bold))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.bordered)
                .disabled(isViewingToday)
                .accessibilityLabel("Next day")
            }

            HStack(spacing: 4) {
                ForEach(visibleWeekDates, id: \.self) { date in
                    Button {
                        selectDate(date)
                    } label: {
                        VStack(spacing: 5) {
                            Text(date.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption2.weight(.semibold))
                            Text(date.formatted(.dateTime.day()))
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 32, height: 32)
                                .background(
                                    Calendar.current.isDate(date, inSameDayAs: selectedDate)
                                        ? ThistleTheme.primaryGreen
                                        : Color.clear,
                                    in: Circle()
                                )
                                .foregroundStyle(
                                    Calendar.current.isDate(date, inSameDayAs: selectedDate)
                                        ? Color.white
                                        : Color.primary
                                )
                            Circle()
                                .fill(hasEntries(on: date) ? ThistleTheme.primaryGreen : Color.clear)
                                .frame(width: 5, height: 5)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isFutureDate(date))
                    .opacity(isFutureDate(date) ? 0.3 : 1)
                    .accessibilityLabel(dayAccessibilityLabel(for: date))
                }
            }

            if !isViewingToday {
                Button("Today") {
                    selectDate(.now)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var selectedDayEntries: [LoggedFood] {
        store.loggedFoods(on: selectedDate)
    }

    private var selectedDayNutrition: NutritionFacts {
        store.nutrition(on: selectedDate)
    }

    private var isViewingToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private var visibleWeekDates: [Date] {
        let calendar = Calendar.current
        let selectedDay = normalizedDate(selectedDate)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: selectedDay)?.start ?? selectedDay
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var recentDiaryDays: [DiaryDaySummary] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: store.loggedFoods) { entry in
            calendar.startOfDay(for: entry.loggedAt)
        }
        return grouped.map { date, entries in
            DiaryDaySummary(
                date: date,
                entryCount: entries.count,
                calories: entries.reduce(0) { $0 + $1.nutrition.calories }
            )
        }
        .sorted { $0.date > $1.date }
        .prefix(8)
        .map { $0 }
    }

    private var foodLoggerButtonTitle: String {
        isViewingToday ? "Log Food" : "Log Food for \(diaryHeaderTitle)"
    }

    private var diaryHeaderTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDate) {
            return "Today"
        }
        if calendar.isDateInYesterday(selectedDate) {
            return "Yesterday"
        }
        return selectedDate.formatted(date: .abbreviated, time: .omitted)
    }

    private func normalizedDate(_ date: Date) -> Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        return min(day, calendar.startOfDay(for: .now))
    }

    private func selectDate(_ date: Date) {
        selectedDate = normalizedDate(date)
    }

    private func moveSelectedDate(by dayOffset: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: selectedDate) else { return }
        selectDate(date)
    }

    private func hasEntries(on date: Date) -> Bool {
        store.loggedFoods.contains { Calendar.current.isDate($0.loggedAt, inSameDayAs: date) }
    }

    private func isFutureDate(_ date: Date) -> Bool {
        normalizedDate(date) < Calendar.current.startOfDay(for: date)
    }

    private func dayTitle(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func dayAccessibilityLabel(for date: Date) -> String {
        let entryDescription = hasEntries(on: date) ? ", has diary entries" : ", no diary entries"
        return date.formatted(date: .complete, time: .omitted) + entryDescription
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Goal Progress")
                .font(.headline)

            MacroSummaryView(nutrition: selectedDayNutrition)

            progressRow(metric: .calories, current: Double(selectedDayNutrition.calories), goal: Double(store.goals.calories))
            progressRow(metric: .protein, current: selectedDayNutrition.protein, goal: store.goals.protein)
            progressRow(metric: .carbs, current: selectedDayNutrition.carbs, goal: store.goals.carbs)
            progressRow(metric: .fat, current: selectedDayNutrition.fat, goal: store.goals.fat)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Other Nutrition Goals")
                    .font(.subheadline.weight(.semibold))
                progressRow(metric: .fiber, current: selectedDayNutrition.fiber, goal: store.goals.fiber)
                progressRow(metric: .iron, current: selectedDayNutrition.ironMg, goal: store.goals.ironMg)
                progressRow(metric: .vitaminD, current: selectedDayNutrition.vitaminDMcg, goal: store.goals.vitaminDMcg)
                progressRow(metric: .saturatedFat, current: selectedDayNutrition.saturatedFat, goal: store.goals.saturatedFatLimit)
                progressRow(metric: .cholesterol, current: selectedDayNutrition.cholesterolMg, goal: store.goals.cholesterolLimitMg)
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
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
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
        NavigationLink {
            LoggedFoodDetailView(entryID: entry.id)
        } label: {
            diaryCard(entry: entry)
        }
        .buttonStyle(.plain)
        .contextMenu {
            diaryContextMenu(entry: entry)
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
                    .tint(progressTint(for: metric, current: current, goal: goal))
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("Show \(metric.title) contributors")
    }

    private func progressTint(for metric: GoalMetric, current: Double, goal: Double) -> Color {
        if metric.isUpperLimit, current > goal {
            return ThistleTheme.warning
        }
        return ThistleTheme.primaryGreen
    }

    private func consumedAmount(for metric: GoalMetric) -> Double {
        switch metric {
        case .calories: return Double(selectedDayNutrition.calories)
        case .protein: return selectedDayNutrition.protein
        case .carbs: return selectedDayNutrition.carbs
        case .fat: return selectedDayNutrition.fat
        case .fiber: return selectedDayNutrition.fiber
        case .iron: return selectedDayNutrition.ironMg
        case .vitaminD: return selectedDayNutrition.vitaminDMcg
        case .saturatedFat: return selectedDayNutrition.saturatedFat
        case .cholesterol: return selectedDayNutrition.cholesterolMg
        }
    }

    private func goalAmount(for metric: GoalMetric) -> Double {
        switch metric {
        case .calories: return Double(store.goals.calories)
        case .protein: return store.goals.protein
        case .carbs: return store.goals.carbs
        case .fat: return store.goals.fat
        case .fiber: return store.goals.fiber
        case .iron: return store.goals.ironMg
        case .vitaminD: return store.goals.vitaminDMcg
        case .saturatedFat: return store.goals.saturatedFatLimit
        case .cholesterol: return store.goals.cholesterolLimitMg
        }
    }
}

private struct DiaryDaySummary: Identifiable {
    let date: Date
    let entryCount: Int
    let calories: Int

    var id: Date { date }
}

struct LoggedFoodDetailView: View {
    @EnvironmentObject private var store: AppStore
    let entryID: String

    @State private var draftServings = 1.0
    @State private var didUpdateServing = false

    private var entry: LoggedFood? {
        store.loggedFoods.first { $0.id == entryID }
    }

    var body: some View {
        ScrollView {
            if let entry {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title)
                                    .font(.title2.weight(.bold))
                                Text(entry.servingText)
                                    .foregroundStyle(.secondary)
                                Text(entry.loggedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            RatingBadge(rating: entry.analysis.rating)
                        }
                        MacroSummaryView(nutrition: entry.nutrition)
                    }
                    .padding()
                    .background(ThistleTheme.cardElevated, in: RoundedRectangle(cornerRadius: 20))

                    IngredientsSection(
                        ingredients: resolvedIngredients(for: entry),
                        analysis: entry.analysis,
                        ingredientsAreEstimated: entry.sourceProductID == nil && linkedProduct(for: entry) == nil
                    )

                    RatingExplanationView(analysis: entry.analysis)

                    let components = resolvedComponents(for: entry)
                    if !components.isEmpty {
                        FoodComponentTreeView(components: components)
                    }

                    if let servings = entry.loggedServings, servings > 0 {
                        servingEditor(entry: entry)
                    }

                    if let product = linkedProduct(for: entry) {
                        NavigationLink {
                            ProductDetailView(product: product)
                        } label: {
                            Label("View source product", systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .onAppear {
                    draftServings = max(entry.loggedServings ?? 1, 0.1)
                }
            } else {
                ContentUnavailableView(
                    "Entry no longer exists",
                    systemImage: "fork.knife.circle",
                    description: Text("It may have been deleted from the diary.")
                )
                .padding()
            }
        }
        .background(ThistleTheme.canvas.ignoresSafeArea())
        .thistleNavigationTitle("Food Details")
    }

    private func servingEditor(entry: LoggedFood) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adjust serving")
                .font(.headline)
            Stepper(value: $draftServings, in: 0.1...20, step: 0.1) {
                Text("\(draftServings.formatted(.number.precision(.fractionLength(0...2)))) x \(entry.baseServingDescription ?? "serving")")
            }
            Button {
                store.updateLoggedFoodServing(entryID: entry.id, servings: draftServings)
                didUpdateServing = true
            } label: {
                Label(didUpdateServing ? "Serving updated" : "Update serving", systemImage: didUpdateServing ? "checkmark.circle.fill" : "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
        .onChange(of: draftServings) { _, _ in
            didUpdateServing = false
        }
    }

    private func linkedProduct(for entry: LoggedFood) -> Product? {
        if let sourceProductID = entry.sourceProductID {
            return store.product(withID: sourceProductID)
        }
        guard entry.sourceProductIDs.count == 1, let sourceProductID = entry.sourceProductIDs.first else {
            return nil
        }
        return store.product(withID: sourceProductID)
    }

    private func resolvedComponents(for entry: LoggedFood) -> [FoodItemComponent] {
        if let components = entry.components, !components.isEmpty {
            return components
        }

        guard entry.sourceProductIDs.count > 1 else { return [] }
        let loggedSourceIDs = Set(entry.sourceProductIDs)
        guard let meal = store.meals.first(where: { meal in
            meal.name == entry.title && Set(meal.components.map(\.product.id)) == loggedSourceIDs
        }) else {
            return []
        }

        return meal.components.map { component in
            let servingText = component.servings == 1
                ? component.product.servingDescription
                : "\(component.servings.formatted(.number.precision(.fractionLength(0...2)))) x \(component.product.servingDescription)"
            return FoodItemComponent(
                title: component.product.name,
                servingText: servingText,
                nutrition: component.product.nutrition * component.servings,
                analysis: store.analysis(for: component.product),
                sourceProductID: component.product.id,
                ingredients: component.product.ingredients
            )
        }
    }

    private func resolvedIngredients(for entry: LoggedFood) -> [String] {
        if let ingredients = entry.ingredients, !ingredients.isEmpty {
            return uniqueIngredients(ingredients)
        }
        if let product = linkedProduct(for: entry), !product.ingredients.isEmpty {
            return uniqueIngredients(product.ingredients)
        }
        let componentIngredients = resolvedComponents(for: entry).flatMap(allIngredients(in:))
        return uniqueIngredients(componentIngredients)
    }

    private func allIngredients(in component: FoodItemComponent) -> [String] {
        (component.ingredients ?? []) + component.components.flatMap(allIngredients(in:))
    }

    private func uniqueIngredients(_ ingredients: [String]) -> [String] {
        var seen: Set<String> = []
        return ingredients.compactMap { ingredient in
            let trimmed = ingredient.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}

private enum GoalMetric: String, Identifiable {
    case calories
    case protein
    case carbs
    case fat
    case fiber
    case iron
    case vitaminD
    case saturatedFat
    case cholesterol

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calories: return "Calories"
        case .protein: return "Protein"
        case .carbs: return "Carbs"
        case .fat: return "Fat"
        case .fiber: return "Fiber"
        case .iron: return "Iron"
        case .vitaminD: return "Vitamin D"
        case .saturatedFat: return "Saturated Fat"
        case .cholesterol: return "Cholesterol"
        }
    }

    var isUpperLimit: Bool {
        switch self {
        case .calories, .saturatedFat, .cholesterol:
            return true
        case .protein, .carbs, .fat, .fiber, .iron, .vitaminD:
            return false
        }
    }

    func value(in nutrition: NutritionFacts) -> Double {
        switch self {
        case .calories: return Double(nutrition.calories)
        case .protein: return nutrition.protein
        case .carbs: return nutrition.carbs
        case .fat: return nutrition.fat
        case .fiber: return nutrition.fiber
        case .iron: return nutrition.ironMg
        case .vitaminD: return nutrition.vitaminDMcg
        case .saturatedFat: return nutrition.saturatedFat
        case .cholesterol: return nutrition.cholesterolMg
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .calories:
            return Int(value.rounded()).formatted()
        case .protein, .carbs, .fat, .fiber, .saturatedFat:
            return "\(value.formatted(.number.precision(.fractionLength(0...1))))g"
        case .iron:
            return "\(value.formatted(.number.precision(.fractionLength(0...1))))mg"
        case .vitaminD:
            return "\(value.formatted(.number.precision(.fractionLength(0...1))))mcg"
        case .cholesterol:
            return "\(value.formatted(.number.precision(.fractionLength(0...0))))mg"
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
