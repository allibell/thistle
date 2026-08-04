import SwiftUI
import VisionKit

struct QuickLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    let loggedAt: Date

    @State private var mode: LoggerMode = .search
    @State private var plateItems: [FoodLogDraftItem] = []

    @State private var searchText = ""
    @State private var onlineResults: [Product] = []
    @State private var isSearchingOnline = false
    @State private var searchError: String?

    @State private var scannedCode: String?
    @State private var scanTask: Task<Void, Never>?

    @State private var descriptionText = ""
    @State private var caloriesText = ""
    @State private var proteinText = ""
    @State private var carbsText = ""
    @State private var fatText = ""
    @State private var estimateMessage: String?
    @State private var estimateIngredients: [String] = []
    @StateObject private var voiceRecorder = FoodVoiceRecorder()
    @State private var isAIWorking = false
    @State private var aiStatusMessage: String?
    @State private var aiErrorMessage: String?
    @State private var showingOpenAISettings = false
    @State private var showingManualEstimate = false

    var body: some View {
        NavigationStack {
            Form {
                if !plateItems.isEmpty {
                    plateSection
                }

                Section {
                    Picker("Logger", selection: $mode) {
                        ForEach(LoggerMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                switch mode {
                case .search:
                    searchSection
                case .scan:
                    scanSection
                case .describe:
                    describeSection
                }
            }
            .navigationTitle("Plate")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Menu {
                        Button {
                            mode = .describe
                            showingManualEstimate = true
                        } label: {
                            Label("Enter nutrition manually", systemImage: "square.and.pencil")
                        }

                        Button {
                            showingOpenAISettings = true
                        } label: {
                            Label("AI settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More logging options")

                    Button(plateItems.isEmpty ? "Log" : "Log \(plateItems.count)") {
                        logPlate()
                    }
                    .fontWeight(.semibold)
                    .disabled(plateItems.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .onDisappear {
            scanTask?.cancel()
            voiceRecorder.cancel()
        }
        .sheet(isPresented: $showingOpenAISettings) {
            OpenAISettingsView()
        }
    }

    private var plateSection: some View {
        Section {
            ForEach($plateItems) { $item in
                HStack(spacing: 10) {
                    NavigationLink {
                        FoodDraftEditorView(item: $item)
                            .environmentObject(store)
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                Text(plateItemSubtitle(item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(item.nutrition.calories) cal")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)

                    Stepper(value: $item.servings, in: 0.1...100, step: 0.1) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Servings for \(item.title)")
                }
                .contextMenu {
                    Button(role: .destructive) {
                        removePlateItem(id: item.id)
                    } label: {
                        Label("Remove from plate", systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                plateItems.remove(atOffsets: offsets)
            }

            MacroSummaryView(nutrition: plateNutrition)
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 4)
        } header: {
            HStack {
                Text("Current Plate")
                Spacer()
                if !plateItems.isEmpty {
                    Text("\(plateNutrition.calories) calories")
                }
            }
        }
    }

    private func plateItemSubtitle(_ item: FoodLogDraftItem) -> String {
        let componentText = item.components.isEmpty
            ? nil
            : "\(item.components.count) component\(item.components.count == 1 ? "" : "s")"
        return [item.servingText, componentText].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var searchSection: some View {
        Section("Find a food") {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Food, dish, or brand", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { searchOnline() }
                    .onChange(of: searchText) { _, _ in
                        onlineResults = []
                        searchError = nil
                    }
            }

            Button {
                searchOnline()
            } label: {
                if isSearchingOnline {
                    Label("Searching…", systemImage: "hourglass")
                } else {
                    Label("Search Online", systemImage: "network")
                }
            }
            .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || isSearchingOnline)

            if let searchError {
                Text(searchError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        if !productSearchResults.isEmpty {
            Section("Results") {
                ForEach(productSearchResults) { product in
                    productResultRow(product)
                }
            }
        }
    }

    @ViewBuilder
    private var scanSection: some View {
        Section {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                BarcodeScannerView(scannedCode: $scannedCode)
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .listRowInsets(EdgeInsets())
            } else {
                Label("Barcode scanning requires a supported physical device.", systemImage: "camera.metering.unknown")
                    .foregroundStyle(.secondary)
            }

            if store.isLookingUpBarcode {
                ProgressView("Looking up barcode…")
            } else if let product = store.barcodeLookupResult {
                productResultRow(product)
            } else if let error = store.barcodeLookupError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Scan Grocery")
        } footer: {
            Text("Scanned products are cached, so the same grocery should resolve instantly next time.")
        }
        .onChange(of: scannedCode) { _, code in
            guard let code else { return }
            scanTask?.cancel()
            scanTask = Task { await store.lookupBarcode(code) }
        }
    }

    @ViewBuilder
    private var describeSection: some View {
        let suggestions = store.rememberedEstimateSuggestions(matching: descriptionText)
        Section("Describe what you ate") {
            TextField(
                "For example: tahini squash bowl from Cafe Réveille",
                text: $descriptionText,
                axis: .vertical
            )
            .lineLimit(3...8)

            HStack(spacing: 10) {
                Button {
                    toggleVoiceRecording()
                } label: {
                    Image(systemName: voiceRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .foregroundStyle(voiceRecorder.isRecording ? ThistleTheme.danger : ThistleTheme.primaryGreen)
                }
                .disabled(isAIWorking)
                .accessibilityLabel(voiceRecorder.isRecording ? "Stop recording" : "Describe by voice")

                if voiceRecorder.isRecording {
                    Text(voiceRecorder.duration.formatted(.number.precision(.fractionLength(1))) + "s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions) { suggestion in
                            Button {
                                applyRemembered(suggestion)
                            } label: {
                                Text("\(suggestion.description) · \(suggestion.nutrition.calories) cal")
                            }
                        }
                    } label: {
                        Label("Recent", systemImage: "clock.arrow.circlepath")
                    }
                }
            }

            Button {
                Task { await analyzeDescriptionWithAI(inputMethod: .typed) }
            } label: {
                if isAIWorking {
                    HStack {
                        ProgressView()
                        Text("Analyzing…")
                    }
                } else {
                    Label("Add editable items", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(ThistleTheme.primaryGreen)
            .disabled(descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAIWorking)

            if let aiStatusMessage {
                Label(aiStatusMessage, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(ThistleTheme.primaryGreen)
            }

            if let aiErrorMessage {
                Text(aiErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(ThistleTheme.danger)
            }
        }

        if showingManualEstimate {
            Section("Manual estimate") {
                Button {
                    estimateLocally()
                } label: {
                    Label("Suggest nutrition from description", systemImage: "function")
                }
                .disabled(descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                nutritionField("Calories", text: $caloriesText, unit: "kcal")
                nutritionField("Protein", text: $proteinText, unit: "g")
                nutritionField("Carbs", text: $carbsText, unit: "g")
                nutritionField("Fat", text: $fatText, unit: "g")

                Button {
                    addEstimateToPlate()
                } label: {
                    Label("Add to Plate", systemImage: "plus.circle.fill")
                }
                .disabled(parsedCalories == nil)

                if let estimateMessage {
                    DisclosureGroup("Estimate details") {
                        Text(estimateMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var productSearchResults: [Product] {
        let local = store.localProductSuggestions(matching: searchText)
        return store.rankedProductSuggestions(local + onlineResults, matching: searchText)
    }

    private func productResultRow(_ product: Product) -> some View {
        HStack(spacing: 12) {
            NavigationLink {
                ProductDetailView(
                    product: product,
                    primaryActionTitle: "Add to Plate",
                    confirmationTitle: "Added!",
                    showsAddToMeal: false,
                    onPrimaryAction: { resolvedProduct, servings in
                        addProductToPlate(resolvedProduct, servings: servings)
                    }
                )
                .environmentObject(store)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(product.name)
                        .font(.subheadline.weight(.semibold))
                    Text("\(product.brand) · \(product.nutrition.calories) cal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows ingredients, nutrition, and serving details")

            Button {
                addProductToPlate(product)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ThistleTheme.primaryGreen)
            .accessibilityLabel("Add \(product.name) to plate")
        }
        .contextMenu {
            Button {
                addProductToPlate(product)
            } label: {
                Label("Add to Plate", systemImage: "plus")
            }
        }
    }

    private func nutritionField(_ title: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }

    private var parsedCalories: Int? {
        guard let value = Int(caloriesText), value > 0 else { return nil }
        return value
    }

    private func parsedMacro(_ text: String) -> Double {
        max(Double(text) ?? 0, 0)
    }

    private var plateNutrition: NutritionFacts {
        plateItems.reduce(.zero) { $0 + $1.nutrition }
    }

    private func addProductToPlate(_ product: Product, servings: Double = 1) {
        if let index = plateItems.firstIndex(where: { $0.sourceProductID == product.id }) {
            plateItems[index].servings += servings
        } else {
            var draft = FoodLogDraftItem(
                product: product,
                analysis: store.analysis(for: product),
                inputMethod: mode == .scan ? .barcode : .catalog
            )
            draft.servings = servings
            plateItems.append(draft)
        }
        if mode == .scan {
            scannedCode = nil
            store.resetBarcodeLookupState(clearManualBarcode: false)
        }
    }

    private func removePlateItem(id: String) {
        withAnimation {
            plateItems.removeAll { $0.id == id }
        }
    }

    private func searchOnline() {
        let query = searchText
        isSearchingOnline = true
        searchError = nil
        Task {
            defer {
                if searchText == query {
                    isSearchingOnline = false
                }
            }
            do {
                let products = try await store.onlineProductSuggestions(matching: query)
                guard searchText == query else { return }
                onlineResults = products
                if products.isEmpty {
                    searchError = "No additional online foods found."
                }
            } catch {
                guard searchText == query else { return }
                searchError = "Online search took too long. Your saved foods are still available."
            }
        }
    }

    private func estimateLocally() {
        guard let estimate = store.quickMealEstimate(description: descriptionText) else { return }
        applyNutrition(estimate.nutrition)
        estimateIngredients = estimate.ingredients
        estimateMessage = estimate.sourceSummary
    }

    private func toggleVoiceRecording() {
        aiErrorMessage = nil
        aiStatusMessage = nil
        if voiceRecorder.isRecording {
            guard let recordingURL = voiceRecorder.stop() else { return }
            Task { await transcribeAndAnalyze(recordingURL) }
            return
        }

        guard OpenAIAPIKeyStore.load() != nil else {
            aiErrorMessage = OpenAIFoodLogError.missingAPIKey.localizedDescription
            showingOpenAISettings = true
            return
        }

        Task {
            do {
                try await voiceRecorder.start()
            } catch {
                aiErrorMessage = error.localizedDescription
            }
        }
    }

    private func transcribeAndAnalyze(_ recordingURL: URL) async {
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        guard let service = configuredOpenAIService() else { return }
        isAIWorking = true
        aiErrorMessage = nil
        aiStatusMessage = "Transcribing voice…"
        do {
            let transcript = try await service.transcribe(fileURL: recordingURL)
            descriptionText = transcript
            aiStatusMessage = "Transcript ready; estimating foods…"
            try await addAIDraft(using: service, inputMethod: .voice)
        } catch {
            aiStatusMessage = nil
            aiErrorMessage = error.localizedDescription
        }
        isAIWorking = false
    }

    private func analyzeDescriptionWithAI(inputMethod: FoodLogInputMethod) async {
        guard let service = configuredOpenAIService() else { return }
        isAIWorking = true
        aiErrorMessage = nil
        aiStatusMessage = nil
        do {
            try await addAIDraft(using: service, inputMethod: inputMethod)
        } catch {
            aiErrorMessage = error.localizedDescription
        }
        isAIWorking = false
    }

    private func addAIDraft(using service: OpenAIFoodLogService, inputMethod: FoodLogInputMethod) async throws {
        let draft = try await service.draft(
            for: FreeformFoodLogRequest(text: descriptionText, inputMethod: inputMethod)
        )
        plateItems.append(contentsOf: draft.items.map { store.applyingIngredientAnalysis(to: $0) })
        aiStatusMessage = "Added \(draft.items.count) editable item\(draft.items.count == 1 ? "" : "s") to your plate."
    }

    private func configuredOpenAIService() -> OpenAIFoodLogService? {
        guard let apiKey = OpenAIAPIKeyStore.load() else {
            aiErrorMessage = OpenAIFoodLogError.missingAPIKey.localizedDescription
            showingOpenAISettings = true
            return nil
        }
        return OpenAIFoodLogService(apiKey: apiKey)
    }

    private func applyRemembered(_ estimate: RememberedMealEstimate) {
        descriptionText = estimate.description
        applyNutrition(estimate.nutrition)
        estimateIngredients = []
        estimateMessage = "Remembered from your previous correction."
    }

    private func applyNutrition(_ nutrition: NutritionFacts) {
        caloriesText = String(nutrition.calories)
        proteinText = nutrition.protein.formatted(.number.precision(.fractionLength(0...1)))
        carbsText = nutrition.carbs.formatted(.number.precision(.fractionLength(0...1)))
        fatText = nutrition.fat.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func addEstimateToPlate() {
        guard let calories = parsedCalories else { return }
        let title = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftItem = FoodLogDraftItem(
                title: title.isEmpty ? "Quick add" : title,
                baseServingDescription: "estimated serving",
                baseNutrition: NutritionFacts(
                    calories: calories,
                    protein: parsedMacro(proteinText),
                    carbs: parsedMacro(carbsText),
                    fat: parsedMacro(fatText)
                ),
                analysis: ProductAnalysis(
                    rating: .yellow,
                    summary: "Quick estimate — edit or replace when more accurate information is available.",
                    flags: []
                ),
                ingredients: estimateIngredients,
                sourceLabel: "Estimate",
                inputMethod: .typed
            )
        plateItems.append(store.applyingIngredientAnalysis(to: draftItem))
        descriptionText = ""
        caloriesText = ""
        proteinText = ""
        carbsText = ""
        fatText = ""
        estimateIngredients = []
        estimateMessage = nil
    }

    private func logPlate() {
        let date = resolvedLogDate
        for item in plateItems {
            store.log(draftItem: item, loggedAt: date)
        }
        dismiss()
    }

    private var resolvedLogDate: Date {
        let calendar = Calendar.current
        if calendar.isDateInToday(loggedAt) { return .now }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: loggedAt) ?? loggedAt
    }
}

private enum LoggerMode: String, CaseIterable, Identifiable {
    case search
    case scan
    case describe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return "Search"
        case .scan: return "Scan"
        case .describe: return "Describe"
        }
    }

    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .scan: return "barcode.viewfinder"
        case .describe: return "text.bubble"
        }
    }
}
