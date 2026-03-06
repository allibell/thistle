import Foundation

protocol ProductCatalogServing: Sendable {
    func searchProducts(matching query: String) async throws -> [Product]
    func product(forBarcode barcode: String) async throws -> Product?
}

enum CatalogError: LocalizedError {
    case invalidQuery

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "Enter at least two characters to search the catalog."
        }
    }
}

struct ProductCatalogService: ProductCatalogServing, Sendable {
    private let openFoodFacts = OpenFoodFactsClient()
    private let upcItemDB = UPCItemDBClient()
    private let localIndex = LocalCatalogSearchIndex.shared

    func searchProducts(matching query: String) async throws -> [Product] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            throw CatalogError.invalidQuery
        }

        let variants = Array(queryVariants(for: trimmed).prefix(2))
        let aggregate = await parallelFetchOpenFoodFacts(variants: variants, maxProducts: 24)

        if aggregate.products.isEmpty, aggregate.encounteredNetworkError {
            // Fail soft: avoid surfacing hard search failures to UI for transient catalog/API issues.
            return []
        }

        let deduped = deduplicate(aggregate.products)
        let sorted = deduped.sorted { rankingScore(for: $0, query: trimmed) > rankingScore(for: $1, query: trimmed) }
        let indexProducts = Array(sorted.prefix(28))
        Task(priority: .utility) { [localIndex] in
            await localIndex.upsert(products: indexProducts)
        }
        return sorted
    }

    private func parallelFetchOpenFoodFacts(variants: [String], maxProducts: Int) async -> (products: [Product], encounteredNetworkError: Bool) {
        guard !variants.isEmpty else { return ([], false) }

        return await withTaskGroup(of: VariantFetchResult.self) { group in
            for variant in variants {
                group.addTask {
                    do {
                        let products = try await openFoodFacts.searchProducts(matching: variant)
                        return VariantFetchResult(products: products, encounteredNetworkError: false)
                    } catch {
                        return VariantFetchResult(products: [], encounteredNetworkError: true)
                    }
                }
            }

            var aggregate: [Product] = []
            var encounteredNetworkError = false
            for await result in group {
                encounteredNetworkError = encounteredNetworkError || result.encounteredNetworkError
                if !result.products.isEmpty {
                    aggregate += result.products
                    if aggregate.count >= maxProducts {
                        group.cancelAll()
                        break
                    }
                }
            }

            return (Array(aggregate.prefix(maxProducts)), encounteredNetworkError)
        }
    }

    func product(forBarcode barcode: String) async throws -> Product? {
        let variants = BarcodeNormalizer.variants(for: barcode)
        guard !variants.isEmpty else { return nil }

        for variant in variants {
            if let product = await localIndex.product(forBarcode: variant) {
                return product
            }
        }

        for variant in variants {
            if let product = (try? await openFoodFacts.product(forBarcode: variant)) ?? nil {
                await localIndex.upsert(products: [product])
                return product
            }
        }

        for variant in variants {
            if let product = (try? await upcItemDB.product(forBarcode: variant)) ?? nil {
                await localIndex.upsert(products: [product])
                return product
            }
        }

        return nil
    }

    private func queryVariants(for query: String) -> [String] {
        let normalized = query.lowercased()
        var variants: [String] = [query]
        let ingredientIntent = isIngredientIntent(query)

        let terms = normalizedTerms(normalized)

        if terms.count >= 2 {
            variants.append(terms.joined(separator: " "))
        }

        if terms.count >= 3 {
            variants.append("\(terms[0]) \(terms[1])")
        }

        if normalized.contains("malk"), !normalized.contains("milk") {
            variants.append(query.replacingOccurrences(of: "malk", with: "malk milk", options: .caseInsensitive))
            variants.append(query.replacingOccurrences(of: "malk", with: "malk organics", options: .caseInsensitive))
        }

        if normalized.contains("unsweetened"), normalized.contains("vanilla") {
            variants.append(query.replacingOccurrences(of: "unsweetened", with: "", options: .caseInsensitive).replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines))
            variants.append("\(query) almond milk")
            variants.append("vanilla almond milk")
        }

        if normalized.contains("malk") {
            variants.append("malk almond milk")
            variants.append("malk vanilla almond milk")
        }

        if terms.contains(where: { $0 == "crisp" || $0 == "crisps" || $0 == "cracker" || $0 == "crackers" }) {
            variants.append(terms.map { $0 == "crisps" ? "crisp" : $0 }.joined(separator: " "))
            variants.append(terms.map { ($0 == "crisp" || $0 == "crisps") ? "crackers" : $0 }.joined(separator: " "))
            variants.append(terms.map { ($0 == "cracker" || $0 == "crackers") ? "crisps" : $0 }.joined(separator: " "))
        }

        let genericTerms = terms.filter { !brandOrStoreNoiseTerms.contains($0) }
        if genericTerms.count >= 2 {
            variants.append(genericTerms.joined(separator: " "))
        }

        if ingredientIntent {
            variants.append("\(query) raw")
            variants.append("\(query) plain")
            variants.append("\(query) unsalted")
        }

        let semantic = semanticTokens(query)
        if semantic.count >= 2 {
            variants.append(semantic.joined(separator: " "))
        }

        var seen: Set<String> = []
        let unique = variants
            .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .filter { value in
                let key = normalizedComparableText(value)
                guard !key.isEmpty else { return false }
                return seen.insert(key).inserted
            }
        return Array(unique.prefix(4))
    }

    private func deduplicate(_ products: [Product]) -> [Product] {
        var byKey: [String: Product] = [:]
        for product in products {
            let key = product.canonicalLookupKey
            if let existing = byKey[key] {
                byKey[key] = product.dataCompletenessScore >= existing.dataCompletenessScore ? product : existing
            } else {
                byKey[key] = product
            }
        }
        return Array(byKey.values)
    }

    private func rankingScore(for product: Product, query: String) -> Int {
        let queryTokens = semanticTokens(query)
        let productTokens = semanticTokens("\(product.brand) \(product.name)")
        let productTokenSet = Set(productTokens)

        let exactMatches = queryTokens.reduce(into: 0) { total, term in
            if productTokenSet.contains(term) { total += 1 }
        }
        let fuzzyMatches = queryTokens.reduce(into: 0) { total, term in
            if productTokenSet.contains(term) { return }
            if productTokenSet.contains(where: { isFuzzyTokenMatch(term, $0) }) {
                total += 1
            }
        }

        var score = ((exactMatches * 22) + (fuzzyMatches * 10)) + (product.dataCompletenessScore * 8)
        let normalizedHaystack = normalizedComparableText("\(product.brand) \(product.name)")
        let normalizedQuery = normalizedComparableText(query)
        if !normalizedQuery.isEmpty, normalizedHaystack.contains(normalizedQuery) {
            score += 30
        }

        if normalizedComparableText(product.brand).contains("trader joe"),
           normalizedQuery.contains("trader joe") || normalizedQuery.contains("tj") {
            score += 24
        }

        if isIngredientIntent(query) {
            score += ingredientSimplicityScore(for: product, queryTerms: Set(queryTokens))
        }

        return score
    }

    private func normalizedTerms(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private func semanticTokens(_ text: String) -> [String] {
        normalizedTerms(normalizedComparableText(text)).map(canonicalToken)
    }

    private func normalizedComparableText(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func canonicalToken(_ token: String) -> String {
        let normalized = token.lowercased()
        if normalized == "tj" || normalized == "tjs" || normalized == "traderjoes" {
            return "trader"
        }
        if normalized == "joes" || normalized == "joe" {
            return "joe"
        }
        if normalized == "crisps" { return "crisp" }
        if normalized == "crackers" { return "cracker" }
        if normalized.hasSuffix("ies"), normalized.count > 3 {
            return String(normalized.dropLast(3)) + "y"
        }
        if normalized.hasSuffix("es"), normalized.count > 4 {
            return String(normalized.dropLast(2))
        }
        if normalized.hasSuffix("s"), normalized.count > 3 {
            return String(normalized.dropLast())
        }
        return normalized
    }

    private func isFuzzyTokenMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lengthGap = abs(lhs.count - rhs.count)
        if lengthGap > 2 { return false }
        let distance = levenshteinDistance(lhs, rhs)
        if min(lhs.count, rhs.count) <= 5 {
            return distance <= 1
        }
        return distance <= 2
    }

    private func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        if lhsChars.isEmpty { return rhsChars.count }
        if rhsChars.isEmpty { return lhsChars.count }

        var previous = Array(0...rhsChars.count)
        for (i, lhsChar) in lhsChars.enumerated() {
            var current = [i + 1]
            for (j, rhsChar) in rhsChars.enumerated() {
                let insertion = current[j] + 1
                let deletion = previous[j + 1] + 1
                let substitution = previous[j] + (lhsChar == rhsChar ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }
        return previous[rhsChars.count]
    }

    private func isIngredientIntent(_ query: String) -> Bool {
        let terms = normalizedTerms(query)
        guard !terms.isEmpty, terms.count <= 2 else { return false }
        let dishTerms: Set<String> = [
            "salad", "soup", "pizza", "sandwich", "tortelloni", "quiche", "lasagna",
            "bowl", "meal", "wrap", "pasta", "dish", "recipe", "frozen", "prepared"
        ]
        return terms.allSatisfy { !dishTerms.contains($0) }
    }

    private func ingredientSimplicityScore(for product: Product, queryTerms: Set<String>) -> Int {
        let nameTerms = Set(normalizedTerms(product.name))
        let overlap = queryTerms.intersection(nameTerms).count
        var score = overlap * 30

        if overlap == queryTerms.count, !queryTerms.isEmpty {
            score += 35
        }

        let normalizedName = product.name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = queryTerms.sorted().joined(separator: " ")
        if normalizedName == normalizedQuery || normalizedName.hasPrefix(normalizedQuery + " ") {
            score += 45
        }

        let dishSignals = [
            "tortelloni", "quiche", "pizza", "salad", "meal", "prepared", "frozen",
            "lasagna", "burrito", "sandwich", "soup", "dhal", "curry", "ricotta", "feta"
        ]
        for signal in dishSignals where normalizedName.contains(signal) {
            score -= 45
        }

        if product.source == .usda {
            score += 20
        }

        return score
    }
}

private struct VariantFetchResult: Sendable {
    var products: [Product]
    var encounteredNetworkError: Bool
}

private let brandOrStoreNoiseTerms: Set<String> = [
    "trader", "joe", "joes", "tj", "tjs", "market", "foods", "whole", "store"
]

private struct OpenFoodFactsClient: Sendable {
    private let session: URLSession
    private let baseURL = URL(string: "https://world.openfoodfacts.org")!

    init(session: URLSession = OpenFoodFactsClient.makeSession()) {
        self.session = session
    }

    func searchProducts(matching query: String) async throws -> [Product] {
        var components = URLComponents(url: baseURL.appending(path: "/cgi/search.pl"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "16"),
            URLQueryItem(name: "fields", value: fields)
        ]
        let request = request(for: components?.url)
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(OpenFoodFactsSearchResponse.self, from: data)
        return response.products
            .compactMap { $0.asProduct() }
    }

    func product(forBarcode barcode: String) async throws -> Product? {
        var components = URLComponents(url: baseURL.appending(path: "/api/v2/product/\(barcode)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "fields", value: fields)]
        let request = request(for: components?.url)
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(OpenFoodFactsBarcodeResponse.self, from: data)
        return response.product?.asProduct()
    }

    private func request(for url: URL?) -> URLRequest {
        var request = URLRequest(url: url ?? baseURL)
        request.setValue("Thistle/0.1 (personal nutrition app; contact: local-dev)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5
        return request
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private var fields: String {
        [
            "code",
            "product_name",
            "brands",
            "ingredients_text",
            "serving_size",
            "stores",
            "image_front_small_url",
            "nutriments"
        ].joined(separator: ",")
    }
}

private struct OpenFoodFactsSearchResponse: Decodable {
    var products: [OpenFoodFactsProduct]
}

private struct OpenFoodFactsBarcodeResponse: Decodable {
    var product: OpenFoodFactsProduct?
}

private struct OpenFoodFactsProduct: Decodable {
    var code: String?
    var productName: String?
    var brands: String?
    var ingredientsText: String?
    var servingSize: String?
    var stores: String?
    var imageFrontSmallURL: URL?
    var nutriments: OpenFoodFactsNutriments?

    enum CodingKeys: String, CodingKey {
        case code
        case productName = "product_name"
        case brands
        case ingredientsText = "ingredients_text"
        case servingSize = "serving_size"
        case stores
        case imageFrontSmallURL = "image_front_small_url"
        case nutriments
    }

    func asProduct() -> Product? {
        let resolvedName = productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !resolvedName.isEmpty else { return nil }

        let barcode = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ingredientList = ingredientsText?
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let storeList = stores?
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        return Product(
            source: .openFoodFacts,
            name: resolvedName,
            brand: brands?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown Brand",
            barcode: barcode,
            stores: Array(Set(storeList)).sorted(),
            servingDescription: servingSize?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "1 serving",
            ingredients: ingredientList,
            nutrition: nutriments?.nutritionFacts ?? .zero,
            imageURL: imageFrontSmallURL
        )
    }
}

private struct OpenFoodFactsNutriments: Decodable {
    var caloriesServing: Double?
    var calories100g: Double?
    var proteinServing: Double?
    var protein100g: Double?
    var carbsServing: Double?
    var carbs100g: Double?
    var fatServing: Double?
    var fat100g: Double?
    var fiberServing: Double?
    var fiber100g: Double?
    var sugarsServing: Double?
    var sugars100g: Double?
    var addedSugarsServing: Double?
    var addedSugars100g: Double?
    var saturatedFatServing: Double?
    var saturatedFat100g: Double?
    var transFatServing: Double?
    var transFat100g: Double?
    var cholesterolServing: Double?
    var cholesterol100g: Double?
    var sodiumServing: Double?
    var sodium100g: Double?
    var potassiumServing: Double?
    var potassium100g: Double?
    var calciumServing: Double?
    var calcium100g: Double?
    var ironServing: Double?
    var iron100g: Double?
    var vitaminDServing: Double?
    var vitaminD100g: Double?
    var vitaminCServing: Double?
    var vitaminC100g: Double?

    enum CodingKeys: String, CodingKey {
        case caloriesServing = "energy-kcal_serving"
        case calories100g = "energy-kcal_100g"
        case proteinServing = "proteins_serving"
        case protein100g = "proteins_100g"
        case carbsServing = "carbohydrates_serving"
        case carbs100g = "carbohydrates_100g"
        case fatServing = "fat_serving"
        case fat100g = "fat_100g"
        case fiberServing = "fiber_serving"
        case fiber100g = "fiber_100g"
        case sugarsServing = "sugars_serving"
        case sugars100g = "sugars_100g"
        case addedSugarsServing = "added-sugars_serving"
        case addedSugars100g = "added-sugars_100g"
        case saturatedFatServing = "saturated-fat_serving"
        case saturatedFat100g = "saturated-fat_100g"
        case transFatServing = "trans-fat_serving"
        case transFat100g = "trans-fat_100g"
        case cholesterolServing = "cholesterol_serving"
        case cholesterol100g = "cholesterol_100g"
        case sodiumServing = "sodium_serving"
        case sodium100g = "sodium_100g"
        case potassiumServing = "potassium_serving"
        case potassium100g = "potassium_100g"
        case calciumServing = "calcium_serving"
        case calcium100g = "calcium_100g"
        case ironServing = "iron_serving"
        case iron100g = "iron_100g"
        case vitaminDServing = "vitamin-d_serving"
        case vitaminD100g = "vitamin-d_100g"
        case vitaminCServing = "vitamin-c_serving"
        case vitaminC100g = "vitamin-c_100g"
    }

    var nutritionFacts: NutritionFacts {
        NutritionFacts(
            calories: Int((caloriesServing ?? calories100g ?? 0).rounded()),
            protein: proteinServing ?? protein100g ?? 0,
            carbs: carbsServing ?? carbs100g ?? 0,
            fat: fatServing ?? fat100g ?? 0,
            fiber: fiberServing ?? fiber100g ?? 0,
            sugars: sugarsServing ?? sugars100g ?? 0,
            addedSugars: addedSugarsServing ?? addedSugars100g ?? 0,
            saturatedFat: saturatedFatServing ?? saturatedFat100g ?? 0,
            transFat: transFatServing ?? transFat100g ?? 0,
            cholesterolMg: normalizedMilligrams(cholesterolServing ?? cholesterol100g),
            sodiumMg: normalizedMilligrams(sodiumServing ?? sodium100g),
            potassiumMg: normalizedMilligrams(potassiumServing ?? potassium100g),
            calciumMg: normalizedMilligrams(calciumServing ?? calcium100g),
            ironMg: normalizedMilligrams(ironServing ?? iron100g),
            vitaminDMcg: vitaminDServing ?? vitaminD100g ?? 0,
            vitaminCMg: normalizedMilligrams(vitaminCServing ?? vitaminC100g)
        )
    }

    // OFF units vary by nutrient; this keeps obvious gram values from being shown as tiny mg values.
    private func normalizedMilligrams(_ value: Double?) -> Double {
        guard let value else { return 0 }
        if value <= 0 { return 0 }
        return value <= 10 ? value * 1000 : value
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct UPCItemDBClient: Sendable {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.upcitemdb.com/prod/trial/lookup")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func product(forBarcode barcode: String) async throws -> Product? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "upc", value: barcode)]
        var request = URLRequest(url: components?.url ?? baseURL)
        request.setValue("Thistle/0.1 (personal nutrition app; contact: local-dev)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(UPCItemDBResponse.self, from: data)
        return response.items.first?.asProduct(scannedBarcode: barcode)
    }
}

private struct UPCItemDBResponse: Decodable {
    var items: [UPCItemDBItem]
}

private struct UPCItemDBItem: Decodable {
    var title: String?
    var brand: String?
    var upc: String?
    var ean: String?
    var images: [URL]?

    func asProduct(scannedBarcode: String) -> Product? {
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !resolvedTitle.isEmpty else { return nil }

        return Product(
            id: Product.makeID(
                source: .upcItemDB,
                barcode: upc ?? ean ?? scannedBarcode,
                name: resolvedTitle,
                brand: brand ?? "Unknown Brand"
            ),
            source: .upcItemDB,
            name: resolvedTitle,
            brand: brand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown Brand",
            barcode: (upc ?? ean ?? scannedBarcode).trimmingCharacters(in: .whitespacesAndNewlines),
            stores: [],
            servingDescription: "1 serving",
            ingredients: [],
            nutrition: .zero,
            imageURL: images?.first
        )
    }
}
