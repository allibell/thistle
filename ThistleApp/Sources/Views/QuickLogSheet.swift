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
    @StateObject private var voiceRecorder = FoodVoiceRecorder()
    @State private var isAIWorking = false
    @State private var aiStatusMessage: String?
    @State private var aiErrorMessage: String?
    @State private var showingOpenAISettings = false

    var body: some View {
        NavigationStack {
            Form {
                plateSection

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
                ToolbarItem(placement: .confirmationAction) {
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
            if plateItems.isEmpty {
                ContentUnavailableView(
                    "Your plate is empty",
                    systemImage: "fork.knife",
                    description: Text("Search, scan, or describe foods below. Log everything together when you’re done.")
                )
            } else {
                ForEach($plateItems) { $item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(item.sourceLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(item.nutrition.calories) cal")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }

                        Stepper(value: $item.servings, in: 0.5...12, step: 0.5) {
                            Text("\(item.servings.formatted(.number.precision(.fractionLength(0...1)))) serving\(item.servings == 1 ? "" : "s")")
                                .font(.caption)
                        }

                        if let confidence = item.confidence {
                            Text("AI confidence: \(Int((confidence * 100).rounded()))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !item.components.isEmpty {
                            Label("\(item.components.count) component\(item.components.count == 1 ? "" : "s")", systemImage: "square.stack.3d.up")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        NavigationLink {
                            FoodDraftEditorView(item: $item)
                                .environmentObject(store)
                        } label: {
                            Label("Review or replace", systemImage: "slider.horizontal.3")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .padding(.vertical, 3)
                }
                .onDelete { offsets in
                    plateItems.remove(atOffsets: offsets)
                }

                MacroSummaryView(nutrition: plateNutrition)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 6)
            }
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

    @ViewBuilder
    private var searchSection: some View {
        Section {
            TextField("Food, brand, or ingredient", text: $searchText)
                .textInputAutocapitalization(.never)
                .onSubmit { searchOnline() }
                .onChange(of: searchText) { _, _ in
                    onlineResults = []
                    searchError = nil
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
        } header: {
            Text("Search")
        } footer: {
            Text("Saved, favorite, and recent foods appear immediately. Use online search only when needed.")
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
        if !suggestions.isEmpty {
            Section("Remembered") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions) { suggestion in
                            Button {
                                applyRemembered(suggestion)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.description)
                                        .lineLimit(1)
                                    Text("\(suggestion.nutrition.calories) cal")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }

        Section {
            TextField(
                "Paste a whole food log, or describe everything you ate…",
                text: $descriptionText,
                axis: .vertical
            )
            .lineLimit(4...12)

            HStack(spacing: 12) {
                Button {
                    toggleVoiceRecording()
                } label: {
                    Label(
                        voiceRecorder.isRecording ? "Stop recording" : "Speak",
                        systemImage: voiceRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .foregroundStyle(voiceRecorder.isRecording ? ThistleTheme.danger : ThistleTheme.primaryGreen)
                }
                .disabled(isAIWorking)

                if voiceRecorder.isRecording {
                    Text(voiceRecorder.duration.formatted(.number.precision(.fractionLength(1))) + "s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showingOpenAISettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("OpenAI settings")
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
                    Label("Analyze into editable items", systemImage: "sparkles")
                }
            }
            .disabled(descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAIWorking)

            Button {
                estimateLocally()
            } label: {
                Label("Use quick local estimate", systemImage: "function")
            }
            .disabled(descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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

            if let estimateMessage {
                Text(estimateMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Describe")
        } footer: {
            Text("AI creates a draft only. Review every item and serving above before tapping Log. Voice recordings are deleted after transcription.")
        }

        Section("Editable Nutrition") {
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
        }
    }

    private var productSearchResults: [Product] {
        let local = store.localProductSuggestions(matching: searchText)
        var seen: Set<String> = []
        return (local + onlineResults).filter { seen.insert($0.id).inserted }
    }

    private func productResultRow(_ product: Product) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(product.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(product.brand) · \(product.nutrition.calories) cal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
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

    private func addProductToPlate(_ product: Product) {
        if let index = plateItems.firstIndex(where: { $0.sourceProductID == product.id }) {
            plateItems[index].servings += 1
        } else {
            plateItems.append(
                FoodLogDraftItem(
                    product: product,
                    analysis: store.analysis(for: product),
                    inputMethod: mode == .scan ? .barcode : .catalog
                )
            )
        }
        if mode == .scan {
            scannedCode = nil
            store.resetBarcodeLookupState(clearManualBarcode: false)
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
        plateItems.append(contentsOf: draft.items)
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
        plateItems.append(
            FoodLogDraftItem(
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
                sourceLabel: "Estimate",
                inputMethod: .typed
            )
        )
        descriptionText = ""
        caloriesText = ""
        proteinText = ""
        carbsText = ""
        fatText = ""
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
