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

    func searchProducts(matching query: String) async throws -> [Product] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            throw CatalogError.invalidQuery
        }
        return try await openFoodFacts.searchProducts(matching: trimmed)
    }

    func product(forBarcode barcode: String) async throws -> Product? {
        let variants = BarcodeNormalizer.variants(for: barcode)
        guard !variants.isEmpty else { return nil }

        for variant in variants {
            if let product = try await openFoodFacts.product(forBarcode: variant) {
                return product
            }
        }

        for variant in variants {
            if let product = try await upcItemDB.product(forBarcode: variant) {
                return product
            }
        }

        return nil
    }
}

private struct OpenFoodFactsClient: Sendable {
    private let session: URLSession
    private let baseURL = URL(string: "https://world.openfoodfacts.org")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchProducts(matching query: String) async throws -> [Product] {
        var components = URLComponents(url: baseURL.appending(path: "/cgi/search.pl"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "24"),
            URLQueryItem(name: "fields", value: fields)
        ]
        let request = request(for: components?.url)
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(OpenFoodFactsSearchResponse.self, from: data)
        return response.products
            .compactMap { $0.asProduct() }
            .filter { !$0.isLowConfidenceCatalogEntry || $0.hasIngredientDetails }
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
        request.timeoutInterval = 20
        return request
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

    enum CodingKeys: String, CodingKey {
        case caloriesServing = "energy-kcal_serving"
        case calories100g = "energy-kcal_100g"
        case proteinServing = "proteins_serving"
        case protein100g = "proteins_100g"
        case carbsServing = "carbohydrates_serving"
        case carbs100g = "carbohydrates_100g"
        case fatServing = "fat_serving"
        case fat100g = "fat_100g"
    }

    var nutritionFacts: NutritionFacts {
        NutritionFacts(
            calories: Int((caloriesServing ?? calories100g ?? 0).rounded()),
            protein: proteinServing ?? protein100g ?? 0,
            carbs: carbsServing ?? carbs100g ?? 0,
            fat: fatServing ?? fat100g ?? 0
        )
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
