import SwiftUI
import Foundation

struct ProductDetailView: View {
    @EnvironmentObject private var store: AppStore
    var product: Product
    @State private var servings = 1.0
    @State private var servingInput = "1"
    @State private var servingInputError: String?
    @State private var expandedIngredientDiffIDs: Set<String> = []
    @State private var didJustLogFood = false
    @State private var logConfirmationTask: Task<Void, Never>?
    @State private var preferredServingUnit: ServingUnitPreference = .native
    @State private var showingManualEditor = false
    @State private var showingAddToMealSheet = false
    @State private var showingMoreNutritionFacts = false

    var body: some View {
        let currentProduct = store.resolvedProduct(for: product)
        let analysis = store.analysis(for: currentProduct)
        let proposal = proposal(for: currentProduct)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentProduct.name)
                                .font(.largeTitle.weight(.bold))
                            Text(currentProduct.brand)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        RatingBadge(rating: analysis.rating)
                    }

                    Text(analysis.summary)
                        .font(.headline)
                        .foregroundStyle(analysis.rating.color)

                    Button {
                        Task { await store.enrich(product: currentProduct, scope: .all) }
                    } label: {
                        if store.isDeepSearchActive(productID: currentProduct.id) {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("BETA: Filling In/Updating...")
                            }
                        } else {
                            Text("BETA: Fill In/Update With Deep Search")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isDeepSearching)

                    Button("Enter Manual Info") {
                        showingManualEditor = true
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.toggleFavorite(currentProduct)
                    } label: {
                        Label(
                            store.isFavorite(currentProduct) ? "Favorited" : "Add To Favorites",
                            systemImage: store.isFavorite(currentProduct) ? "heart.fill" : "heart"
                        )
                    }
                    .buttonStyle(.bordered)

                    storesSection(for: currentProduct)

                    macrosSection(for: currentProduct)
                    moreNutritionFactsSection(for: currentProduct)
                }
                .padding()
                .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Serving")
                        .font(.headline)

                    if let servingMeasurement = parseServingMeasurement(from: currentProduct.servingDescription),
                       servingMeasurement.availableUnits.count > 1 {
                        Picker("Serving Unit", selection: $preferredServingUnit) {
                            ForEach(servingMeasurement.availableUnits, id: \.self) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Stepper(value: $servings, in: 0.1...12, step: 0.5) {
                        Text("\(formattedServingCount(servings)) x \(formattedServingDescription(currentProduct.servingDescription))")
                    }
                    .onChange(of: servings) { _, newValue in
                        servingInput = formattedServingCount(newValue)
                        servingInputError = nil
                    }

                    HStack(spacing: 8) {
                        TextField("Servings", text: $servingInput)
                            .keyboardType(.numbersAndPunctuation)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                _ = applyServingInput()
                            }

                        Button("Set") {
                            _ = applyServingInput()
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Use decimals or fractions, e.g. 0.1 or 1/2.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let servingInputError {
                        Text(servingInputError)
                            .font(.caption)
                            .foregroundStyle(ThistleTheme.warning)
                    }

                    HStack(spacing: 10) {
                        Button("Log Food") {
                            guard applyServingInput() else { return }
                            store.log(product: currentProduct, servings: servings)
                            showLogConfirmation()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Add To Meal") {
                            guard applyServingInput() else { return }
                            showingAddToMealSheet = true
                        }
                        .buttonStyle(.bordered)

                        if didJustLogFood {
                            Label("Logged!", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ThistleTheme.primaryGreen)
                                .transition(.opacity.combined(with: .scale))
                        }
                    }
                }
                .padding()
                .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))

                IngredientsSection(product: currentProduct, analysis: analysis)
                    .contextMenu {
                        Button("BETA: Fill In/Update Ingredients") {
                            Task { await store.enrich(product: currentProduct, scope: .ingredients) }
                        }
                    }

                if let proposal {
                    proposalSection(proposal, currentProduct: currentProduct)
                }

                if store.isDeepSearchActive(productID: currentProduct.id) || !store.deepSearchDebugLog.isEmpty {
                    debugSection
                }
            }
            .padding()
        }
        .background(ThistleTheme.canvas.ignoresSafeArea())
        .thistleNavigationTitle("Details")
        .onAppear {
            syncPreferredServingUnit(for: product.servingDescription)
            servingInput = formattedServingCount(servings)
        }
        .onChange(of: currentProduct.servingDescription) { _, newValue in
            syncPreferredServingUnit(for: newValue)
        }
        .onDisappear {
            logConfirmationTask?.cancel()
            logConfirmationTask = nil
        }
        .sheet(isPresented: $showingManualEditor) {
            ProductEntrySheet(
                existingProduct: currentProduct,
                defaultQuery: currentProduct.name,
                allowLinkMode: false
            )
        }
        .sheet(isPresented: $showingAddToMealSheet) {
            AddProductToMealSheet(product: currentProduct, servings: servings)
        }
    }

    private func showLogConfirmation() {
        logConfirmationTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            didJustLogFood = true
        }

        logConfirmationTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) {
                    didJustLogFood = false
                }
            }
        }
    }

    @discardableResult
    private func applyServingInput() -> Bool {
        guard let parsed = parseServingAmount(servingInput) else {
            servingInputError = "Enter a valid serving amount like 0.1 or 1/2."
            return false
        }

        let clamped = min(max(parsed, 0.1), 12)
        servings = clamped
        servingInput = formattedServingCount(clamped)
        servingInputError = nil
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

    private func syncPreferredServingUnit(for servingDescription: String) {
        guard let servingMeasurement = parseServingMeasurement(from: servingDescription) else {
            preferredServingUnit = .native
            return
        }
        if !servingMeasurement.availableUnits.contains(preferredServingUnit) {
            preferredServingUnit = servingMeasurement.defaultUnit
        } else {
            preferredServingUnit = servingMeasurement.defaultUnit == .native ? preferredServingUnit : servingMeasurement.defaultUnit
        }
    }

    private func formattedServingCount(_ servings: Double) -> String {
        servings.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func formattedServingDescription(_ rawDescription: String) -> String {
        guard let servingMeasurement = parseServingMeasurement(from: rawDescription),
              preferredServingUnit != .native else {
            return roundedNumericText(in: rawDescription)
        }

        switch servingMeasurement {
        case .volume(let measurement, _, _):
            let converted: Measurement<UnitVolume>
            let symbol: String
            switch preferredServingUnit {
            case .milliliters:
                converted = measurement.converted(to: .milliliters)
                symbol = "mL"
            case .fluidOunces:
                converted = measurement.converted(to: .fluidOunces)
                symbol = "fl oz"
            default:
                return roundedNumericText(in: rawDescription)
            }
            return "\(formatDecimal(converted.value, fractionDigits: 2)) \(symbol)"
        case .mass(let measurement, _, _):
            let converted: Measurement<UnitMass>
            let symbol: String
            switch preferredServingUnit {
            case .grams:
                converted = measurement.converted(to: .grams)
                symbol = "g"
            case .ounces:
                converted = measurement.converted(to: .ounces)
                symbol = "oz"
            default:
                return roundedNumericText(in: rawDescription)
            }
            return "\(formatDecimal(converted.value, fractionDigits: 2)) \(symbol)"
        }
    }

    private func roundedNumericText(in text: String) -> String {
        let pattern = #"\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = text
        let matches = regex.matches(in: text, options: [], range: nsRange).reversed()
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let sourceNumber = String(text[range])
            guard let value = Double(sourceNumber) else { continue }
            let replacement = formatDecimal(value, fractionDigits: 2)
            if let resultRange = Range(match.range, in: result) {
                result.replaceSubrange(resultRange, with: replacement)
            }
        }
        return result
    }

    private func formatDecimal(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(0...fractionDigits))
                .rounded(rule: .toNearestOrEven, increment: 0.01)
        )
    }

    private func parseServingMeasurement(from text: String) -> ParsedServingMeasurement? {
        let pattern = #"(?i)(\d+(?:\.\d+)?)\s*(fl\s*oz|milliliters?|ml|liters?|l|cups?|tbsp|tablespoons?|tsp|teaspoons?|kilograms?|kg|grams?|g|ounces?|oz|pounds?|lbs?|lb)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard let match = matches.last,
              let amountRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let amount = Double(text[amountRange]) else {
            return nil
        }

        let token = text[unitRange].lowercased().replacingOccurrences(of: " ", with: "")
        let normalizedToken = token.hasSuffix("s") ? String(token.dropLast()) : token

        switch normalizedToken {
        case "ml", "milliliter":
            return .volume(Measurement(value: amount, unit: .milliliters), nativeLabel: "mL", defaultUnit: .milliliters)
        case "l", "liter":
            return .volume(Measurement(value: amount, unit: .liters), nativeLabel: "L", defaultUnit: .milliliters)
        case "floz":
            return .volume(Measurement(value: amount, unit: .fluidOunces), nativeLabel: "fl oz", defaultUnit: .fluidOunces)
        case "cup":
            return .volume(Measurement(value: amount, unit: .cups), nativeLabel: "cup", defaultUnit: .fluidOunces)
        case "tbsp", "tablespoon":
            return .volume(Measurement(value: amount, unit: .tablespoons), nativeLabel: "tbsp", defaultUnit: .fluidOunces)
        case "tsp", "teaspoon":
            return .volume(Measurement(value: amount, unit: .teaspoons), nativeLabel: "tsp", defaultUnit: .fluidOunces)
        case "g", "gram":
            return .mass(Measurement(value: amount, unit: .grams), nativeLabel: "g", defaultUnit: .grams)
        case "kg", "kilogram":
            return .mass(Measurement(value: amount, unit: .kilograms), nativeLabel: "kg", defaultUnit: .grams)
        case "oz", "ounce":
            return .mass(Measurement(value: amount, unit: .ounces), nativeLabel: "oz", defaultUnit: .ounces)
        case "lb", "lbs", "pound":
            return .mass(Measurement(value: amount, unit: .pounds), nativeLabel: "lb", defaultUnit: .ounces)
        default:
            return nil
        }
    }

    private func storesSection(for product: Product) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Available At")
                .font(.headline)
            Text(product.stores.isEmpty ? "No store data yet." : product.stores.joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("BETA: Fill In/Update Stores") {
                Task { await store.enrich(product: product, scope: .stores) }
            }
        }
    }

    private func macrosSection(for product: Product) -> some View {
        MacroSummaryView(nutrition: product.nutrition * servings)
            .contextMenu {
                Button("BETA: Fill In/Update Macros") {
                    Task { await store.enrich(product: product, scope: .macros) }
                }
            }
    }

    private func moreNutritionFactsSection(for product: Product) -> some View {
        let nutrition = product.nutrition * servings
        let facts = nutrition.additionalNutritionFacts

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingMoreNutritionFacts.toggle()
                }
            } label: {
                HStack {
                    Text("More nutrition facts")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showingMoreNutritionFacts ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.plain)

            if showingMoreNutritionFacts {
                if facts.isEmpty {
                    Text("No additional nutrition facts available yet for this item.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(facts) { fact in
                        HStack {
                            Text(fact.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formattedNutritionFact(fact))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func formattedNutritionFact(_ fact: NutritionDetailFact) -> String {
        let value = fact.value.formatted(
            .number
                .precision(.fractionLength(0...1))
                .rounded(rule: .toNearestOrEven, increment: 0.1)
        )
        return "\(value) \(fact.unit)"
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Deep Search Debug")
                    .font(.headline)
                if store.isDeepSearchActive(productID: product.id) {
                    ProgressView()
                }
            }

            if store.deepSearchDebugLog.isEmpty {
                Text("Waiting for deep search updates...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(store.deepSearchDebugLog.enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func proposal(for product: Product) -> DeepSearchProposal? {
        guard let proposal = store.pendingDeepSearchProposal, proposal.productID == product.id else {
            return nil
        }
        return proposal
    }

    private func proposalSection(_ proposal: DeepSearchProposal, currentProduct: Product) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deep Search Review")
                .font(.headline)

            Text("Does this look like the right update info?")
                .font(.subheadline)

            Text("Confidence \(proposal.confidenceScore)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if !proposal.confidenceReasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(proposal.confidenceReasons, id: \.self) { reason in
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(proposal.changedFields) { diff in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(diff.label)
                                .font(.subheadline.weight(.semibold))
                            if diff.addsMissingData {
                                Text("fills missing")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(ThistleTheme.primaryGreen.opacity(0.15), in: Capsule())
                            }
                        }

                        if diff.kind == .ingredients {
                            let oldIngredients = currentProduct.ingredients
                            let newIngredients = proposal.mergedProduct.ingredients
                            let isExpanded = expandedIngredientDiffIDs.contains(diff.id)
                            let oldPreviewCount = min(oldIngredients.count, 3)
                            let newPreviewCount = min(newIngredients.count, 3)
                            let oldHiddenCount = max(0, oldIngredients.count - oldPreviewCount)
                            let newHiddenCount = max(0, newIngredients.count - newPreviewCount)
                            let canExpand = oldHiddenCount > 0 || newHiddenCount > 0
                            let maxHidden = max(oldHiddenCount, newHiddenCount)

                            if isExpanded {
                                Text("Current: \(oldIngredients.isEmpty ? "Missing" : oldIngredients.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Update: \(newIngredients.isEmpty ? "Missing" : newIngredients.joined(separator: ", "))")
                                    .font(.caption)
                            } else {
                                Text("Current: \(diff.oldValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Update: \(diff.newValue)")
                                    .font(.caption)
                            }

                            if canExpand {
                                Button {
                                    if isExpanded {
                                        expandedIngredientDiffIDs.remove(diff.id)
                                    } else {
                                        expandedIngredientDiffIDs.insert(diff.id)
                                    }
                                } label: {
                                    Text(isExpanded ? "Show less" : "+\(maxHidden) more")
                                        .font(.caption.weight(.semibold))
                                        .underline(true, color: ThistleTheme.blossomPurple)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(ThistleTheme.blossomPurple)
                            }
                        } else {
                            Text("Current: \(diff.oldValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Update: \(diff.newValue)")
                                .font(.caption)
                        }
                    }
                    if diff.id != proposal.changedFields.last?.id {
                        Divider()
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Apply Update") {
                    store.approvePendingDeepSearchProposal()
                }
                .buttonStyle(.borderedProminent)

                Button("Reject") {
                    store.rejectPendingDeepSearchProposal()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

private enum ServingUnitPreference: String, Hashable {
    case native
    case milliliters
    case fluidOunces
    case grams
    case ounces

    var label: String {
        switch self {
        case .native: return "Original"
        case .milliliters: return "mL"
        case .fluidOunces: return "fl oz"
        case .grams: return "g"
        case .ounces: return "oz"
        }
    }
}

private enum ParsedServingMeasurement {
    case volume(Measurement<UnitVolume>, nativeLabel: String, defaultUnit: ServingUnitPreference)
    case mass(Measurement<UnitMass>, nativeLabel: String, defaultUnit: ServingUnitPreference)

    var availableUnits: [ServingUnitPreference] {
        switch self {
        case .volume:
            return [.native, .milliliters, .fluidOunces]
        case .mass:
            return [.native, .grams, .ounces]
        }
    }

    var defaultUnit: ServingUnitPreference {
        switch self {
        case .volume(_, _, let defaultUnit):
            return defaultUnit
        case .mass(_, _, let defaultUnit):
            return defaultUnit
        }
    }
}
