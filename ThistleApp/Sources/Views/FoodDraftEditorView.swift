import SwiftUI

struct FoodDraftEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var item: FoodLogDraftItem

    @State private var replacementQuery = ""
    @State private var onlineResults: [Product] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var showingAdvancedDetails = false
    @State private var showingReplacementSearch = false

    var body: some View {
        Form {
            Section {
                TextField("Food name", text: $item.title)
                    .font(.headline)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quantity")
                        Text(item.servingText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper(value: $item.servings, in: 0.1...100, step: 0.1) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                MacroSummaryView(nutrition: item.nutrition)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 4)
            }

            Section {
                ForEach($item.components) { $component in
                    HStack(spacing: 10) {
                        NavigationLink {
                            FoodDraftEditorView(item: $component)
                                .environmentObject(store)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(component.title)
                                Text("\(component.servingText) · \(component.nutrition.calories) cal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button(role: .destructive) {
                            removeComponent(id: component.id)
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(component.title)")
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            removeComponent(id: component.id)
                        } label: {
                            Label("Remove component", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    item.components.remove(atOffsets: offsets)
                }

                Button {
                    item.components.append(newComponent)
                } label: {
                    Label("Add component", systemImage: "plus.circle")
                }
            } header: {
                Text("Components")
            } footer: {
                Text("Components describe this food; the parent nutrition above remains the logged total.")
            }

            if showingAdvancedDetails {
                Section("Serving and source") {
                    TextField("Base serving", text: $item.baseServingDescription)
                    LabeledContent("Source", value: item.sourceLabel)
                    if let confidence = item.confidence {
                        LabeledContent("AI confidence", value: "\(Int((confidence * 100).rounded()))%")
                    }
                }

                Section("Nutrition per base serving") {
                    numberField("Calories", value: $item.baseNutrition.calories, unit: "kcal")
                    numberField("Protein", value: $item.baseNutrition.protein, unit: "g")
                    numberField("Carbs", value: $item.baseNutrition.carbs, unit: "g")
                    numberField("Fat", value: $item.baseNutrition.fat, unit: "g")
                    numberField("Fiber", value: $item.baseNutrition.fiber, unit: "g")
                }

                Section("Ingredients") {
                    ForEach(item.ingredients.indices, id: \.self) { index in
                        HStack {
                            TextField("Ingredient", text: $item.ingredients[index])
                            Button(role: .destructive) {
                                item.ingredients.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove ingredient")
                        }
                    }
                    Button {
                        item.ingredients.append("")
                    } label: {
                        Label("Add ingredient", systemImage: "plus.circle")
                    }
                }

                if !item.notes.isEmpty {
                    Section("AI estimate notes") {
                        ForEach(item.notes, id: \.self) { note in
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if showingReplacementSearch {
                Section("Find a different food") {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Food, dish, or brand", text: $replacementQuery)
                            .submitLabel(.search)
                            .onSubmit { searchOnline() }
                            .onChange(of: replacementQuery) { _, _ in
                                onlineResults = []
                                searchError = nil
                            }
                    }

                    Button {
                        searchOnline()
                    } label: {
                        if isSearching {
                            ProgressView("Searching…")
                        } else {
                            Label("Search online", systemImage: "network")
                        }
                    }
                    .disabled(replacementQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || isSearching)

                    if let searchError {
                        Text(searchError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(replacementResults) { product in
                        Button {
                            replace(with: product)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.name)
                                        .foregroundStyle(.primary)
                                    Text("\(product.brand) · \(product.nutrition.calories) cal")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("Use")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            }
        }
        .thistleNavigationTitle("Review Food")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingAdvancedDetails.toggle()
                    } label: {
                        Label(
                            showingAdvancedDetails ? "Hide nutrition details" : "Edit nutrition and ingredients",
                            systemImage: "slider.horizontal.3"
                        )
                    }

                    Button {
                        showingReplacementSearch.toggle()
                    } label: {
                        Label(
                            showingReplacementSearch ? "Hide replacement search" : "Find a different food",
                            systemImage: "magnifyingglass"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More food options")
            }
        }
    }

    private var replacementResults: [Product] {
        let local = store.localProductSuggestions(matching: replacementQuery)
        return store.rankedProductSuggestions(local + onlineResults, matching: replacementQuery, limit: 12)
    }

    private var newComponent: FoodLogDraftItem {
        FoodLogDraftItem(
            title: "New component",
            baseServingDescription: "1 serving",
            baseNutrition: .zero,
            analysis: ProductAnalysis(
                rating: .yellow,
                summary: "Manually added component; review its serving and nutrition.",
                flags: []
            ),
            sourceLabel: "Manual",
            inputMethod: .manual
        )
    }

    private func numberField(_ title: String, value: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
        }
    }

    private func numberField(_ title: String, value: Binding<Int>, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
        }
    }

    private func searchOnline() {
        let query = replacementQuery
        isSearching = true
        searchError = nil
        Task {
            defer {
                if replacementQuery == query {
                    isSearching = false
                }
            }
            do {
                let results = try await store.onlineProductSuggestions(matching: query)
                guard replacementQuery == query else { return }
                onlineResults = results
                if replacementResults.isEmpty {
                    searchError = "No matching foods found. You can still edit the estimate manually."
                }
            } catch {
                guard replacementQuery == query else { return }
                searchError = error.localizedDescription
            }
        }
    }

    private func replace(with product: Product) {
        let originalInputMethod = item.inputMethod
        item = FoodLogDraftItem(
            product: product,
            analysis: store.analysis(for: product),
            inputMethod: originalInputMethod
        )
        replacementQuery = ""
        onlineResults = []
        showingReplacementSearch = false
    }

    private func removeComponent(id: String) {
        withAnimation {
            item.components.removeAll { $0.id == id }
        }
    }
}

struct OpenAISettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var foodModel = OpenAIConfiguration.foodModel
    @State private var transcriptionModel = OpenAIConfiguration.transcriptionModel
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Personal OpenAI API key")
                } footer: {
                    Text("Stored only in this device’s Keychain. It is never written to Thistle’s state file or source code.")
                }

                Section("Models") {
                    TextField("Food parsing model", text: $foodModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Transcription model", text: $transcriptionModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Text("This direct-key option is suitable for a personal development build. Before distributing Thistle, proxy OpenAI requests through an authenticated backend so no shared secret lives in the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(ThistleTheme.danger)
                    }
                }
            }
            .navigationTitle("OpenAI")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                apiKey = OpenAIAPIKeyStore.load() ?? ""
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        do {
            try OpenAIAPIKeyStore.save(apiKey)
            OpenAIConfiguration.foodModel = foodModel
            OpenAIConfiguration.transcriptionModel = transcriptionModel
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
