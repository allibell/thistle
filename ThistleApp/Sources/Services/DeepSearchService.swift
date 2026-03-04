import Foundation

protocol DeepSearchServing: Sendable {
    func deepSearchProduct(matching query: String) async throws -> Product?
}

struct DeepSearchService: DeepSearchServing, Sendable {
    private let usda = USDAFoodDataCentralClient()
    private let web = WebFallbackClient()

    func deepSearchProduct(matching query: String) async throws -> Product? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }

        async let usdaCandidate = usda.searchProduct(matching: trimmed)
        async let webCandidate = web.searchProduct(matching: trimmed)

        let nutritionSeed = try await usdaCandidate
        let webSeed = try await webCandidate

        guard nutritionSeed != nil || webSeed != nil else { return nil }

        if let webSeed, let nutritionSeed {
            return Product(
                source: .deepSearch,
                name: bestTitle(primary: webSeed.name, fallback: nutritionSeed.name, query: trimmed),
                brand: bestTitle(primary: webSeed.brand, fallback: nutritionSeed.brand, query: ""),
                barcode: nutritionSeed.barcode.isEmpty ? webSeed.barcode : nutritionSeed.barcode,
                stores: Array(Set(webSeed.stores + nutritionSeed.stores)).sorted(),
                servingDescription: preferredServing(primary: webSeed.servingDescription, fallback: nutritionSeed.servingDescription),
                ingredients: webSeed.ingredients.isEmpty ? nutritionSeed.ingredients : webSeed.ingredients,
                nutrition: webSeed.hasMeaningfulNutrition ? webSeed.nutrition : nutritionSeed.nutrition,
                imageURL: webSeed.imageURL ?? nutritionSeed.imageURL
            )
        }

        if let webSeed { return webSeed }
        return nutritionSeed
    }

    private func bestTitle(primary: String, fallback: String, query: String) -> String {
        if !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return primary }
        if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return fallback }
        return query
    }

    private func preferredServing(primary: String, fallback: String) -> String {
        if primary != "1 serving" { return primary }
        return fallback
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
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(USDAFoodSearchResponse.self, from: data)
        return response.foods.first?.asProduct()
    }
}

private struct USDAFoodSearchResponse: Decodable {
    var foods: [USDAFood]
}

private struct USDAFood: Decodable {
    var description: String
    var brandOwner: String?
    var gtinUpc: String?
    var servingSize: Double?
    var servingSizeUnit: String?
    var foodNutrients: [USDAFoodNutrient]

    func asProduct() -> Product {
        Product(
            source: .usda,
            name: description.capitalized,
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
            foodNutrients.first { nutrient in
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
}

private struct WebFallbackClient: Sendable {
    private let session: URLSession
    private let searchURL = URL(string: "https://html.duckduckgo.com/html/")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchProduct(matching query: String) async throws -> Product? {
        let urls = try await searchResultURLs(for: "\"\(query)\" ingredients nutrition")
        for url in urls.prefix(4) {
            if let product = try await scrapeProduct(from: url, query: query) {
                return product
            }
        }
        return nil
    }

    private func searchResultURLs(for query: String) async throws -> [URL] {
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, _) = try await session.data(for: URLRequest(url: components?.url ?? searchURL))
        let html = String(decoding: data, as: UTF8.self)

        let matches = html.matches(for: #"result__a" href="([^"]+)""#)
        return matches.compactMap { match in
            let cleaned = match.replacingOccurrences(of: "&amp;", with: "&")
            return URL(string: cleaned)
        }
    }

    private func scrapeProduct(from url: URL, query: String) async throws -> Product? {
        let request = URLRequest(url: url, timeoutInterval: 20)
        let (data, _) = try await session.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        let text = html
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let ingredients = extractIngredients(from: text)
        let nutrition = extractNutrition(from: text)

        guard !ingredients.isEmpty || nutrition != .zero else { return nil }

        let pageTitle = html.firstMatch(for: #"<title>([^<]+)</title>"#)?
            .replacingOccurrences(of: " |.*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? query

        return Product(
            source: .deepSearch,
            name: pageTitle,
            brand: inferBrand(from: pageTitle, query: query),
            barcode: "",
            stores: [],
            servingDescription: "1 serving",
            ingredients: ingredients,
            nutrition: nutrition
        )
    }

    private func extractIngredients(from text: String) -> [String] {
        guard let raw = text.firstMatch(for: #"(?i)ingredients?\s*[:\-]\s*(.{20,500}?)((nutrition facts|contains|distributed by|warning|allergen|$))"#) else {
            return []
        }

        return raw
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count < 80 }
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
