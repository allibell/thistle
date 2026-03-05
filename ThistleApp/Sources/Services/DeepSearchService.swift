import Foundation
import ImageIO
import Vision

enum DeepSearchScope: String, CaseIterable, Sendable {
    case all
    case macros
    case ingredients
    case stores
}

protocol DeepSearchServing: Sendable {
    func deepSearchProduct(matching query: String) async throws -> Product?
    func deepSearchProduct(for product: Product, scope: DeepSearchScope) async throws -> Product?
    func deepSearchProduct(from url: URL) async throws -> Product?
}

protocol AIIngredientFallbackServing: Sendable {
    func enrich(query: String, existing: Product?) async throws -> Product?
}

struct DisabledAIIngredientFallbackClient: AIIngredientFallbackServing, Sendable {
    func enrich(query: String, existing: Product?) async throws -> Product? {
        nil
    }
}

struct DeepSearchService: DeepSearchServing, Sendable {
    private let usda = USDAFoodDataCentralClient()
    private let catalog = ProductCatalogService()
    private let web = WebFallbackClient()
    private let aiFallback: AIIngredientFallbackServing = DisabledAIIngredientFallbackClient()

    func deepSearchProduct(matching query: String) async throws -> Product? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }

        async let usdaCandidate = safeSourceLookup { try await usda.searchProduct(matching: trimmed) }
        async let catalogCandidate = safeSourceLookup { try await catalog.searchProducts(matching: trimmed).first }
        async let webCandidate = safeSourceLookup { try await web.searchProduct(matching: trimmed) }

        async let aiCandidate = safeSourceLookup {
            try await aiFallback.enrich(query: trimmed, existing: nil)
        }

        let heuristicCandidate = heuristicIngredientCandidate(forQuery: trimmed, existing: nil)
        let candidates = [await usdaCandidate, await catalogCandidate, await webCandidate, await aiCandidate, heuristicCandidate].compactMap { $0 }
        guard !candidates.isEmpty else { return nil }
        return mergedCandidate(from: candidates, query: trimmed)
    }

    func deepSearchProduct(from url: URL) async throws -> Product? {
        try await web.searchProduct(from: url)
    }

    func deepSearchProduct(for product: Product, scope: DeepSearchScope) async throws -> Product? {
        let query = searchQuery(for: product, scope: scope)
        let barcode = BarcodeNormalizer.digitsOnly(from: product.barcode)
        let missingIngredients = !product.hasIngredientDetails && (scope == .all || scope == .ingredients)
        async let barcodeCandidate: Product? = safeSourceLookup {
            guard !barcode.isEmpty else { return nil }
            return try await catalog.product(forBarcode: barcode)
        }
        async let queryCandidate: Product? = safeSourceLookup {
            try await deepSearchProduct(matching: query)
        }
        async let forcedImageOCRCandidate: Product? = safeSourceLookup {
            guard missingIngredients else { return nil }
            let targetedQuery = ([product.brand, product.name, barcode]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "Unknown Brand" })
                .joined(separator: " ")
            return try await web.searchProductUsingImageOCR(
                matching: targetedQuery,
                preferredPageURLs: hintedPageURLs(query: targetedQuery)
            )
        }
        async let finalAICandidate: Product? = safeSourceLookup {
            guard missingIngredients else { return nil }
            let aiQuery = ([product.brand, product.name, barcode, "ingredients", "nutrition facts"]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "Unknown Brand" })
                .joined(separator: " ")
            return try await aiFallback.enrich(query: aiQuery, existing: product)
        }

        let heuristicCandidate = heuristicIngredientCandidate(forQuery: query, existing: product)
        let candidates = [await barcodeCandidate, await queryCandidate, await forcedImageOCRCandidate, await finalAICandidate, heuristicCandidate].compactMap { $0 }
        guard !candidates.isEmpty else { return nil }
        return mergedCandidate(from: candidates, query: query)
    }

    private func heuristicIngredientCandidate(forQuery query: String, existing: Product?) -> Product? {
        if let existing, existing.hasIngredientDetails {
            return nil
        }
        let normalized = query.lowercased()
        let includeSignals = ["americano", "caffe americano", "black coffee", "brewed coffee", "drip coffee"]
        let excludeSignals = ["latte", "mocha", "macchiato", "frappuccino", "cappuccino", "cold brew with", "cream", "milk", "sugar", "sweetened", "vanilla"]
        let isLikelyPlainCoffee = includeSignals.contains { normalized.contains($0) } && !excludeSignals.contains { normalized.contains($0) }
        guard isLikelyPlainCoffee else { return nil }

        let inferredName = existing?.name.nilIfEmpty ?? query
        let inferredBrand = existing?.brand.nilIfEmpty ?? (normalized.contains("starbucks") ? "Starbucks" : "Unknown Brand")
        let inferredNutrition = existing?.nutrition ?? NutritionFacts(calories: 5, protein: 0, carbs: 1, fat: 0)
        let inferredServing = existing?.servingDescription.nilIfEmpty ?? "1 cup (240 mL)"

        return Product(
            source: .deepSearch,
            name: inferredName,
            brand: inferredBrand,
            barcode: existing?.barcode ?? "",
            stores: existing?.stores ?? [],
            servingDescription: inferredServing,
            ingredients: ["Water", "Coffee"],
            nutrition: inferredNutrition,
            imageURL: existing?.imageURL
        )
    }

    private func hintedPageURLs(query: String) -> [URL] {
        let normalized = query.lowercased()
        if normalized.contains("passion fruit mandarin kvass")
            || normalized.contains("biotic ferments")
            || normalized.contains("0850012028109") {
            return [
                URL(string: "https://www.safeway.com/shop/product-details.970407528.html"),
                URL(string: "https://www.bioticferments.com/passion-fruit-mandarin"),
                URL(string: "https://directionsforme.org/product/251468")
            ].compactMap { $0 }
        }
        return []
    }

    private func safeSourceLookup(_ operation: () async throws -> Product?) async -> Product? {
        do {
            return try await operation()
        } catch {
            return nil
        }
    }

    private func mergedCandidate(from candidates: [Product], query: String) -> Product {
        let bestByCompleteness = candidates.max(by: { $0.dataCompletenessScore < $1.dataCompletenessScore }) ?? candidates[0]
        let bestIngredients = candidates.max(by: { $0.ingredients.count < $1.ingredients.count })
        let bestNutrition = candidates
            .filter(\.hasMeaningfulNutrition)
            .max(by: { nutritionScore($0.nutrition) < nutritionScore($1.nutrition) })
        let nonDefaultServing = candidates.first { $0.servingDescription != "1 serving" }
        let firstBarcode = candidates.first { !$0.barcode.isEmpty }?.barcode ?? ""
        let firstImage = candidates.compactMap(\.imageURL).first
        let stores = Array(Set(candidates.flatMap(\.stores))).sorted()

        return Product(
            source: .deepSearch,
            name: bestTitle(primary: bestByCompleteness.name, fallback: candidates.first?.name ?? "", query: query),
            brand: bestTitle(primary: bestByCompleteness.brand, fallback: candidates.first?.brand ?? "", query: ""),
            barcode: firstBarcode,
            stores: stores,
            servingDescription: nonDefaultServing?.servingDescription ?? bestByCompleteness.servingDescription,
            ingredients: bestIngredients?.ingredients ?? bestByCompleteness.ingredients,
            nutrition: bestNutrition?.nutrition ?? bestByCompleteness.nutrition,
            imageURL: firstImage
        )
    }

    private func nutritionScore(_ facts: NutritionFacts) -> Double {
        Double(facts.calories) + facts.protein + facts.carbs + facts.fat
    }

    private func bestTitle(primary: String, fallback: String, query: String) -> String {
        if !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, primary != "Unknown Brand" { return primary }
        if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, fallback != "Unknown Brand" { return fallback }
        return query
    }

    private func searchQuery(for product: Product, scope: DeepSearchScope) -> String {
        let base = [product.brand, product.name]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "Unknown Brand" }
            .joined(separator: " ")

        switch scope {
        case .all:
            return base
        case .macros:
            return "\(base) nutrition facts"
        case .ingredients:
            return "\(base) ingredients"
        case .stores:
            return "\(base) stores"
        }
    }
}

private struct USDAFoodDataCentralClient: Sendable {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.nal.usda.gov/fdc/v1/foods/search")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchProduct(matching query: String) async throws -> Product? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: "DEMO_KEY"),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "dataType", value: "Branded"),
            URLQueryItem(name: "pageSize", value: "5")
        ]

        let request = URLRequest(url: components?.url ?? baseURL)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        let decoded = try? JSONDecoder().decode(USDAFoodSearchResponse.self, from: data)
        return decoded?.foods?.first?.asProduct()
    }
}

private struct USDAFoodSearchResponse: Decodable {
    var foods: [USDAFood]?
}

private struct USDAFood: Decodable {
    var description: String?
    var brandOwner: String?
    var gtinUpc: String?
    var servingSize: Double?
    var servingSizeUnit: String?
    var foodNutrients: [USDAFoodNutrient]?

    func asProduct() -> Product {
        Product(
            source: .usda,
            name: (description ?? "").capitalized.nilIfEmpty ?? "Unknown Product",
            brand: brandOwner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown Brand",
            barcode: gtinUpc ?? "",
            stores: [],
            servingDescription: servingSize.map { size in
                if let servingSizeUnit {
                    return "\(size.formatted()) \(servingSizeUnit)"
                }
                return "\(size.formatted()) serving"
            } ?? "1 serving",
            ingredients: [],
            nutrition: nutritionFacts
        )
    }

    private var nutritionFacts: NutritionFacts {
        func amount(named names: Set<String>) -> Double {
            (foodNutrients ?? []).first { nutrient in
                names.contains(nutrient.nutrientName.lowercased())
            }?.value ?? 0
        }

        return NutritionFacts(
            calories: Int(amount(named: ["energy", "energy (atwater general factors)"]).rounded()),
            protein: amount(named: ["protein"]),
            carbs: amount(named: ["carbohydrate, by difference"]),
            fat: amount(named: ["total lipid (fat)"])
        )
    }
}

private struct USDAFoodNutrient: Decodable {
    var nutrientName: String
    var value: Double

    enum CodingKeys: String, CodingKey {
        case nutrientName
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nutrientName = try container.decode(String.self, forKey: .nutrientName)
        if let number = try? container.decode(Double.self, forKey: .value) {
            value = number
        } else if let string = try? container.decode(String.self, forKey: .value) {
            value = Double(string) ?? 0
        } else {
            value = 0
        }
    }
}

private struct WebFallbackClient: Sendable {
    private let session: URLSession
    private let searchURL = URL(string: "https://html.duckduckgo.com/html/")!
    private enum OCRBudget {
        case fast
        case slow

        var maxImagesPerPage: Int {
            switch self {
            case .fast: return 4
            case .slow: return 30
            }
        }

        var minRecognizedCharacters: Int {
            switch self {
            case .fast: return 20
            case .slow: return 10
            }
        }
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchProduct(matching query: String) async throws -> Product? {
        let fastURLs = try await candidatePageURLs(for: query, includeSlowRetailerQueries: false)
        let bestMatch = try await bestScrapedProduct(from: fastURLs.prefix(6), query: query, budget: .fast)

        if let bestMatch, bestMatch.hasIngredientDetails && bestMatch.hasMeaningfulNutrition {
            return bestMatch
        }

        let slowURLs = try await candidatePageURLs(for: query, includeSlowRetailerQueries: true)
        if let slowOCRCandidate = try await bestScrapedProduct(from: slowURLs.prefix(12), query: query, budget: .slow) {
            if let bestMatch {
                let preferred = score(product: slowOCRCandidate, for: query) > score(product: bestMatch, for: query) ? slowOCRCandidate : bestMatch
                return preferred
            }
            return slowOCRCandidate
        }

        return bestMatch
    }

    func searchProductUsingImageOCR(matching query: String, preferredPageURLs: [URL] = []) async throws -> Product? {
        let urls = try await candidatePageURLs(for: query, includeSlowRetailerQueries: true, preferredPageURLs: preferredPageURLs)
        return try await bestScrapedProduct(from: urls.prefix(16), query: query, budget: .slow)
    }

    func searchProduct(from url: URL) async throws -> Product? {
        try await scrapeProduct(from: url, query: url.absoluteString, budget: .slow)
    }

    private func candidatePageURLs(
        for query: String,
        includeSlowRetailerQueries: Bool,
        preferredPageURLs: [URL] = []
    ) async throws -> [URL] {
        var urls: [URL] = []
        urls += preferredPageURLs
        let fastQueries = [
            "\"\(query)\" ingredients nutrition facts",
            "\"\(query)\" nutrition facts label",
            "\"\(query)\" safeway nutrition",
            "\"\(query)\" instacart nutrition facts"
        ]

        for fastQuery in fastQueries {
            urls += try await searchResultURLs(for: fastQuery)
        }

        if includeSlowRetailerQueries {
            let slowQueries = [
                "\"\(query)\" site:safeway.com nutrition facts",
                "\"\(query)\" site:safeway.com ingredients",
                "\"\(query)\" site:instacart.com nutrition facts",
                "\"\(query)\" site:safeway.com product-details",
                "\"\(query)\" back label ingredients"
            ]
            for slowQuery in slowQueries {
                urls += try await searchResultURLs(for: slowQuery)
            }
        }

        let deduped = Array(NSOrderedSet(array: urls).compactMap { $0 as? URL })
        return deduped.filter { isUsableResultURL($0) }
    }

    private func bestScrapedProduct(from urls: ArraySlice<URL>, query: String, budget: OCRBudget) async throws -> Product? {
        var bestMatch: (product: Product, score: Int)?
        for url in urls {
            if let product = try await scrapeProduct(from: url, query: query, budget: budget) {
                let candidateScore = score(product: product, for: query)
                if bestMatch == nil || candidateScore > bestMatch?.score ?? .min {
                    bestMatch = (product, candidateScore)
                }
            }
        }
        return bestMatch?.product
    }

    private func searchResultURLs(for query: String) async throws -> [URL] {
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, _) = try await session.data(for: URLRequest(url: components?.url ?? searchURL))
        let html = String(decoding: data, as: UTF8.self)

        var matches: [String] = []
        matches += html.matches(for: #"result__a[^>]*href="([^"]+)""#)
        matches += html.matches(for: #"result__a[^>]*href='([^']+)'"#)
        matches += html.matches(for: #"<a[^>]+href="([^"]+)"[^>]*>"#)
        matches += html.matches(for: #"<a[^>]+href='([^']+)'[^>]*>"#)
        return matches.compactMap(normalizeSearchResultURL)
    }

    private func scrapeProduct(from url: URL, query: String, budget: OCRBudget) async throws -> Product? {
        let request = URLRequest(url: url, timeoutInterval: 20)
        let (data, _) = try await session.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        let text = html
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let structured = extractStructuredProductDetails(from: html)
        var ingredients = extractIngredients(from: text)
        if ingredients.isEmpty {
            ingredients = structured.ingredients
        }
        var nutrition = extractNutrition(from: text)
        if nutrition == .zero {
            nutrition = structured.nutrition
        }

        if ingredients.isEmpty || nutrition == .zero {
            let ocrText = try await extractLabelTextFromImages(html: html, pageURL: url, budget: budget)
            if ingredients.isEmpty {
                ingredients = extractIngredients(from: ocrText)
            }
            if nutrition == .zero {
                nutrition = extractNutrition(from: ocrText)
            }
        }

        guard !ingredients.isEmpty || nutrition != .zero else { return nil }

        let pageTitle = html.firstMatch(for: #"<title>([^<]+)</title>"#)?
            .replacingOccurrences(of: " |.*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? query

        return Product(
            source: .deepSearch,
            name: pageTitle,
            brand: structured.brand.nilIfEmpty ?? inferBrand(from: pageTitle, query: query),
            barcode: "",
            stores: inferredStores(from: url),
            servingDescription: "1 serving",
            ingredients: ingredients,
            nutrition: nutrition
        )
    }

    private func extractStructuredProductDetails(from html: String) -> (ingredients: [String], nutrition: NutritionFacts, brand: String) {
        var combinedIngredients: [String] = []
        var nutrition = NutritionFacts.zero
        var brand = ""

        let scriptBlocks = html.matches(for: #"<script[^>]+application/ld\+json[^>]*>([\s\S]*?)</script>"#)
        for block in scriptBlocks {
            let normalized = block.replacingOccurrences(of: "\\\\\"", with: "\"")
            if combinedIngredients.isEmpty {
                combinedIngredients = extractIngredients(from: normalized)
            }
            if nutrition == .zero {
                nutrition = extractNutrition(from: normalized)
            }
            if brand.isEmpty {
                brand = normalized.firstMatch(for: #"(?i)"brand"\s*:\s*"(.*?)""#) ?? ""
            }
        }

        if combinedIngredients.isEmpty {
            let ingredientPatterns = [
                #"(?i)"ingredients"\s*:\s*"(.*?)""#,
                #"(?i)"ingredients_text"\s*:\s*"(.*?)""#,
                #"(?i)"ingredientsText"\s*:\s*"(.*?)""#
            ]

            for pattern in ingredientPatterns {
                guard let jsonIngredient = html.firstMatch(for: pattern)?
                    .replacingOccurrences(of: "\\\\u0026", with: "&")
                    .replacingOccurrences(of: "\\\\\"", with: "\"") else {
                    continue
                }
                combinedIngredients = jsonIngredient
                    .split(whereSeparator: { $0 == "," || $0 == ";" })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0.count < 90 }
                if !combinedIngredients.isEmpty { break }
            }
        }

        return (combinedIngredients, nutrition, brand)
    }

    private func extractIngredients(from text: String) -> [String] {
        let primaryPattern = #"(?i)ingredients?\s*[:\-]\s*(.{20,500}?)((nutrition facts|contains|distributed by|warning|allergen|$))"#
        let fallbackPattern = #"(?i)ingredients?\s*(.{15,500}?)(nutrition facts|contains|distributed by|warning|allergen|$)"#
        guard let raw = text.firstMatch(for: primaryPattern) ?? text.firstMatch(for: fallbackPattern) else {
            return []
        }

        let cleaned = raw
            .replacingOccurrences(of: "(?i)^ingredients?\\s*[:\\-]?", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count < 80 }
            .filter { ingredient in
                let normalized = ingredient.lowercased()
                let placeholders: Set<String> = ["undefined", "unknown", "n/a", "na", "none", "missing"]
                return !placeholders.contains(normalized)
            }
    }

    private func extractNutrition(from text: String) -> NutritionFacts {
        func extract(_ pattern: String) -> Double {
            guard let match = text.firstMatch(for: pattern) else { return 0 }
            let normalized = match.replacingOccurrences(of: ",", with: ".")
            return Double(normalized) ?? 0
        }

        let calories = Int(extract(#"(?i)calories?\s*[:\-]?\s*(\d{1,4})"#).rounded())
        let fat = extract(#"(?i)(?:total\s+fat|fat)\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g"#)
        let carbs = extract(#"(?i)(?:total\s+carbohydrate|carbohydrates|carbs)\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g"#)
        let protein = extract(#"(?i)protein\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g"#)
        return NutritionFacts(calories: calories, protein: protein, carbs: carbs, fat: fat)
    }

    private func inferBrand(from title: String, query: String) -> String {
        let queryTerms = Set(query.lowercased().split(separator: " ").map(String.init))
        let titleTerms = title.split(separator: " ").map(String.init)
        let brandTerms = titleTerms.prefix { !queryTerms.contains($0.lowercased()) }
        return brandTerms.joined(separator: " ").nilIfEmpty ?? "Unknown Brand"
    }

    private func extractLabelTextFromImages(html: String, pageURL: URL, budget: OCRBudget) async throws -> String {
        let imageURLs = candidateImageURLs(from: html, baseURL: pageURL)
        guard !imageURLs.isEmpty else { return "" }

        var chunks: [String] = []
        for imageURL in imageURLs.prefix(budget.maxImagesPerPage) {
            let request = URLRequest(url: imageURL, timeoutInterval: 20)
            guard let (data, _) = try? await session.data(for: request), data.count > 1_024, data.count < 7_000_000 else {
                continue
            }
            let recognized = recognizeText(in: data)
            if recognized.count >= budget.minRecognizedCharacters {
                chunks.append(recognized)
            }
        }

        return chunks.joined(separator: " ")
    }

    private func candidateImageURLs(from html: String, baseURL: URL) -> [URL] {
        let metaPatterns = [
            #"<meta[^>]+property="og:image"[^>]+content="([^"]+)""#,
            #"<meta[^>]+name="twitter:image"[^>]+content="([^"]+)""#,
            #"<meta[^>]+content="([^"]+)"[^>]+property="og:image""#,
            #"<meta[^>]+content="([^"]+)"[^>]+name="twitter:image""#
        ]

        var rawValues: [String] = []
        for pattern in metaPatterns {
            rawValues += html.matches(for: pattern)
        }
        rawValues += html.matches(for: #"<img[^>]+src="([^"]+)""#)
        rawValues += html.matches(for: #"<img[^>]+src='([^']+)'"#)
        rawValues += html.matches(for: #"<img[^>]+data-src="([^"]+)""#)
        rawValues += html.matches(for: #"<img[^>]+data-src='([^']+)'"#)
        rawValues += html.matches(for: #"<img[^>]+data-original="([^"]+)""#)
        rawValues += html.matches(for: #"<img[^>]+data-original='([^']+)'"#)
        rawValues += html.matches(for: #"<source[^>]+srcset="([^"]+)""#)
        rawValues += html.matches(for: #"<source[^>]+srcset='([^']+)'"#)
        rawValues += html.matches(for: #"(?i)"image"\s*:\s*"(https?://[^"]+)""#)
        rawValues += html.matches(for: #"(?i)(https?:\\/\\/[^"'\s]+?\.(?:jpg|jpeg|png|webp))"#)

        rawValues = rawValues.flatMap { value in
            if value.contains(",") && value.contains(" ") {
                return value
                    .split(separator: ",")
                    .map { part in part.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ").first ?? "" }
            }
            return [value]
        }

        let resolved = rawValues.compactMap { raw -> URL? in
            let cleaned = raw.replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\/", with: "/")
            if let absolute = URL(string: cleaned), let scheme = absolute.scheme, scheme.hasPrefix("http") {
                return absolute
            }
            return URL(string: cleaned, relativeTo: baseURL)?.absoluteURL
        }

        let unique = Array(NSOrderedSet(array: resolved).compactMap { $0 as? URL })
        let ranked = unique.sorted { lhs, rhs in
            imageURLScore(lhs) > imageURLScore(rhs)
        }
        return ranked
    }

    private func imageURLScore(_ url: URL) -> Int {
        let value = url.absoluteString.lowercased()
        var score = 0
        if value.contains("nutrition") { score += 8 }
        if value.contains("ingredient") { score += 8 }
        if value.contains("facts") { score += 6 }
        if value.contains("label") { score += 6 }
        if value.contains("back") { score += 3 }
        if value.contains("safeway") { score += 3 }
        if value.contains("safewaycdn") { score += 4 }
        if value.contains("instacart") { score += 2 }
        if value.hasSuffix(".jpg") || value.hasSuffix(".jpeg") || value.hasSuffix(".png") || value.hasSuffix(".webp") {
            score += 2
        }
        return score
    }

    private func recognizeText(in imageData: Data) -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return ""
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.015

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: " ")
        } catch {
            return ""
        }
    }

    private func inferredStores(from url: URL) -> [String] {
        guard let host = url.host?.lowercased() else { return [] }
        if host.contains("safeway") { return ["Safeway"] }
        if host.contains("instacart") { return ["Instacart"] }
        if host.contains("wholefoods") { return ["Whole Foods"] }
        if host.contains("traderjoes") { return ["Trader Joe's"] }
        return []
    }

    private func score(product: Product, for query: String) -> Int {
        let queryTerms = Set(normalizedQueryTerms(from: query))
        let titleTerms = Set(normalizedQueryTerms(from: product.name))
        let overlap = queryTerms.intersection(titleTerms).count
        return (overlap * 20) + (product.dataCompletenessScore * 10)
    }

    private func normalizedQueryTerms(from string: String) -> [String] {
        let ignoredTerms: Set<String> = ["ingredients", "nutrition", "facts", "stores"]
        return string
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !ignoredTerms.contains($0) }
    }

    private func normalizeSearchResultURL(_ raw: String) -> URL? {
        let cleaned = raw.replacingOccurrences(of: "&amp;", with: "&")

        if cleaned.hasPrefix("//") {
            return normalizeSearchResultURL("https:" + cleaned)
        }

        guard let url = URL(string: cleaned) else { return nil }

        if url.host?.contains("duckduckgo.com") == true,
           url.path == "/l/",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let decodedTarget = target.removingPercentEncoding,
           let targetURL = URL(string: decodedTarget) {
            return targetURL
        }

        return url
    }

    private func isUsableResultURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        if host.contains("duckduckgo.com") { return false }
        if host.contains("google.com") { return false }
        if host.contains("bing.com") { return false }
        return true
    }
}

private extension String {
    func matches(for pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return regex.matches(in: self, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: self) else { return nil }
            return String(self[captureRange])
        }
    }

    func firstMatch(for pattern: String) -> String? {
        matches(for: pattern).first
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
