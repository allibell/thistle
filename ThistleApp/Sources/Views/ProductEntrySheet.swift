import SwiftUI
import VisionKit

enum ProductEntryMode: String, CaseIterable, Identifiable {
    case link = "Link"
    case manual = "Manual"

    var id: String { rawValue }
}

struct ProductEntrySheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let existingProduct: Product?
    let defaultQuery: String
    let allowLinkMode: Bool

    @State private var mode: ProductEntryMode = .manual
    @State private var linkInput = ""

    @State private var name = ""
    @State private var brand = ""
    @State private var barcode = ""
    @State private var servingDescription = "1 serving"
    @State private var ingredientsText = ""
    @State private var caloriesText = ""
    @State private var proteinText = ""
    @State private var carbsText = ""
    @State private var fatText = ""
    @State private var fiberText = ""
    @State private var storesText = ""
    @State private var imageURLText = ""

    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showScanner = false
    @State private var scannedCode: String?

    var body: some View {
        NavigationStack {
            Form {
                if allowLinkMode {
                    Section("Entry Mode") {
                        Picker("Mode", selection: $mode) {
                            ForEach(ProductEntryMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if mode == .link, allowLinkMode {
                    linkSection
                } else {
                    manualSection
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(ThistleTheme.warning)
                    }
                }
            }
            .navigationTitle(existingProduct == nil ? "Add Product" : "Edit Product")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Saving..." : actionTitle) {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || isPrimaryActionDisabled)
                }
            }
            .onAppear(perform: hydrateFromExisting)
            .onChange(of: scannedCode) { _, newValue in
                guard let newValue else { return }
                barcode = newValue
            }
        }
    }

    private var actionTitle: String {
        if mode == .link, allowLinkMode {
            return "Import"
        }
        return existingProduct == nil ? "Add" : "Save"
    }

    private var isPrimaryActionDisabled: Bool {
        if mode == .link, allowLinkMode {
            return linkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var linkSection: some View {
        Section("Paste Product Link") {
            TextField("https://...", text: $linkInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            Text("We will parse and scrape this page to build a product entry.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var manualSection: some View {
        Group {
            Section("Identity") {
                TextField("Product Name", text: $name)
                TextField("Brand", text: $brand)
                TextField("Barcode", text: $barcode)
                    .keyboardType(.numberPad)

                Button("Go To Scan View") {
                    store.selectedTab = .scan
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button(showScanner ? "Hide Barcode Scanner" : "Scan Barcode") {
                    showScanner.toggle()
                }
                .disabled(!DataScannerViewController.isSupported || !DataScannerViewController.isAvailable)

                if showScanner, DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    BarcodeScannerView(scannedCode: $scannedCode)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }

            Section("Serving") {
                TextField("Serving Description", text: $servingDescription)
            }

            Section("Ingredients") {
                TextField("Comma-separated ingredients", text: $ingredientsText, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section("Macros (per serving)") {
                macroField(label: "Calories", shortLabel: "Cal", text: $caloriesText, useDecimalPad: false)
                macroField(label: "Protein (g)", shortLabel: "P", text: $proteinText, useDecimalPad: true)
                macroField(label: "Carbs (g)", shortLabel: "C", text: $carbsText, useDecimalPad: true)
                macroField(label: "Fat (g)", shortLabel: "F", text: $fatText, useDecimalPad: true)
                macroField(label: "Fiber (g)", shortLabel: "Fi", text: $fiberText, useDecimalPad: true)
            }

            Section("Optional") {
                TextField("Stores (comma-separated)", text: $storesText)
                TextField("Image URL", text: $imageURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
        }
    }

    @ViewBuilder
    private func macroField(label: String, shortLabel: String, text: Binding<String>, useDecimalPad: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 88, alignment: .leading)

            TextField(label, text: text)
                .keyboardType(useDecimalPad ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func submit() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        if mode == .link, allowLinkMode {
            do {
                let imported = try await store.addProductFromLink(linkInput, fallbackQuery: defaultQuery)
                if imported == nil {
                    errorMessage = "Could not parse a product from that link. Try Manual mode."
                    return
                }
                dismiss()
            } catch {
                errorMessage = "Could not import from link. Try Manual mode."
            }
            return
        }

        let calories = Int(caloriesText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let protein = Double(proteinText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let carbs = Double(carbsText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let fat = Double(fatText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let fiber = Double(fiberText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        _ = store.saveManualProduct(
            existingProductID: existingProduct?.id,
            name: name,
            brand: brand,
            barcode: barcode,
            servingDescription: servingDescription,
            ingredientsText: ingredientsText,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            fiber: fiber,
            storesText: storesText,
            imageURLText: imageURLText
        )
        dismiss()
    }

    private func hydrateFromExisting() {
        guard let existingProduct else {
            if !defaultQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = defaultQuery
            }
            return
        }

        mode = .manual
        name = existingProduct.name
        brand = existingProduct.brand
        barcode = existingProduct.barcode
        servingDescription = existingProduct.servingDescription
        ingredientsText = existingProduct.ingredients.joined(separator: ", ")
        caloriesText = "\(existingProduct.nutrition.calories)"
        proteinText = existingProduct.nutrition.protein.formatted(.number.precision(.fractionLength(0...2)))
        carbsText = existingProduct.nutrition.carbs.formatted(.number.precision(.fractionLength(0...2)))
        fatText = existingProduct.nutrition.fat.formatted(.number.precision(.fractionLength(0...2)))
        fiberText = existingProduct.nutrition.fiber.formatted(.number.precision(.fractionLength(0...2)))
        storesText = existingProduct.stores.joined(separator: ", ")
        imageURLText = existingProduct.imageURL?.absoluteString ?? ""
    }
}
