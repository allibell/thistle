import Foundation
import SQLite3

actor LocalCatalogSearchIndex {
    static let shared = LocalCatalogSearchIndex()

    private let fileURL: URL
    private var db: OpaquePointer?
    private let isoFormatter = ISO8601DateFormatter()

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folderURL = appSupport.appendingPathComponent("Thistle", isDirectory: true)
        fileURL = folderURL.appendingPathComponent("catalog-index.sqlite")
        db = Self.openAndMigrateDatabase(at: fileURL, fileManager: fileManager, directory: folderURL)
    }

    func upsert(products: [Product]) {
        guard !products.isEmpty else { return }
        guard let db else { return }

        execute("BEGIN IMMEDIATE TRANSACTION;")
        defer { execute("COMMIT;") }

        let sql = """
        INSERT OR REPLACE INTO indexed_products (
            id, source, name, brand, barcode, barcode_digits, stores_json, serving_description,
            ingredients_json, calories, protein, carbs, fat, fiber, image_url, user_edited_at,
            last_updated_at, canonical_key
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        let ftsDeleteSQL = "DELETE FROM indexed_products_fts WHERE id = ?;"
        let ftsInsertSQL = """
        INSERT INTO indexed_products_fts (id, name, brand, barcode, stores, ingredients, canonical_key)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """

        var upsertStatement: OpaquePointer?
        var ftsDeleteStatement: OpaquePointer?
        var ftsInsertStatement: OpaquePointer?
        defer {
            sqlite3_finalize(upsertStatement)
            sqlite3_finalize(ftsDeleteStatement)
            sqlite3_finalize(ftsInsertStatement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &upsertStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, ftsDeleteSQL, -1, &ftsDeleteStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, ftsInsertSQL, -1, &ftsInsertStatement, nil) == SQLITE_OK else {
            return
        }

        for product in products {
            sqlite3_reset(upsertStatement)
            sqlite3_clear_bindings(upsertStatement)

            bindText(product.id, to: 1, in: upsertStatement)
            bindText(product.source.rawValue, to: 2, in: upsertStatement)
            bindText(product.name, to: 3, in: upsertStatement)
            bindText(product.brand, to: 4, in: upsertStatement)
            bindText(product.barcode, to: 5, in: upsertStatement)
            bindText(product.barcode.filter(\.isNumber), to: 6, in: upsertStatement)
            bindText(encodedJSONArray(product.stores), to: 7, in: upsertStatement)
            bindText(product.servingDescription, to: 8, in: upsertStatement)
            bindText(encodedJSONArray(product.ingredients), to: 9, in: upsertStatement)
            sqlite3_bind_int64(upsertStatement, 10, sqlite3_int64(product.nutrition.calories))
            sqlite3_bind_double(upsertStatement, 11, product.nutrition.protein)
            sqlite3_bind_double(upsertStatement, 12, product.nutrition.carbs)
            sqlite3_bind_double(upsertStatement, 13, product.nutrition.fat)
            sqlite3_bind_double(upsertStatement, 14, product.nutrition.fiber)
            bindText(product.imageURL?.absoluteString ?? "", to: 15, in: upsertStatement)
            bindText(product.userEditedAt.map(isoFormatter.string(from:)) ?? "", to: 16, in: upsertStatement)
            bindText(isoFormatter.string(from: product.lastUpdatedAt), to: 17, in: upsertStatement)
            bindText(product.canonicalLookupKey, to: 18, in: upsertStatement)

            if sqlite3_step(upsertStatement) != SQLITE_DONE { continue }

            sqlite3_reset(ftsDeleteStatement)
            sqlite3_clear_bindings(ftsDeleteStatement)
            bindText(product.id, to: 1, in: ftsDeleteStatement)
            _ = sqlite3_step(ftsDeleteStatement)

            sqlite3_reset(ftsInsertStatement)
            sqlite3_clear_bindings(ftsInsertStatement)
            bindText(product.id, to: 1, in: ftsInsertStatement)
            bindText(normalizedIndexText(product.name), to: 2, in: ftsInsertStatement)
            bindText(normalizedIndexText(product.brand), to: 3, in: ftsInsertStatement)
            bindText(product.barcode.filter(\.isNumber), to: 4, in: ftsInsertStatement)
            bindText(normalizedIndexText(product.stores.joined(separator: " ")), to: 5, in: ftsInsertStatement)
            bindText(normalizedIndexText(product.ingredients.joined(separator: " ")), to: 6, in: ftsInsertStatement)
            bindText(normalizedIndexText(product.canonicalLookupKey), to: 7, in: ftsInsertStatement)
            _ = sqlite3_step(ftsInsertStatement)
        }
    }

    func searchProducts(matching query: String, limit: Int = 20) -> [Product] {
        guard let db else { return [] }
        let ftsQuery = buildFTSQuery(from: query)
        guard !ftsQuery.isEmpty else { return [] }

        let sql = """
        SELECT p.id, p.source, p.name, p.brand, p.barcode, p.stores_json, p.serving_description,
               p.ingredients_json, p.calories, p.protein, p.carbs, p.fat, p.fiber, p.image_url,
               p.user_edited_at, p.last_updated_at
        FROM indexed_products_fts f
        JOIN indexed_products p ON p.id = f.id
        WHERE indexed_products_fts MATCH ?
        ORDER BY bm25(indexed_products_fts, 8.0, 5.0, 2.0, 1.5, 1.2, 1.0)
        LIMIT ?;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        bindText(ftsQuery, to: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(max(1, limit)))

        var products: [Product] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let product = product(from: statement) {
                products.append(product)
            }
        }
        return products
    }

    func product(forBarcode barcode: String) -> Product? {
        guard let db else { return nil }
        let digits = barcode.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }

        let sql = """
        SELECT id, source, name, brand, barcode, stores_json, serving_description,
               ingredients_json, calories, protein, carbs, fat, fiber, image_url,
               user_edited_at, last_updated_at
        FROM indexed_products
        WHERE barcode_digits = ?
        ORDER BY last_updated_at DESC
        LIMIT 1;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }

        bindText(digits, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return product(from: statement)
    }

    private static func openAndMigrateDatabase(at fileURL: URL, fileManager: FileManager, directory: URL) -> OpaquePointer? {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &pointer, flags, nil) == SQLITE_OK else {
            if let pointer { sqlite3_close(pointer) }
            return nil
        }
        migrateIfNeeded(db: pointer)
        return pointer
    }

    private static func migrateIfNeeded(db: OpaquePointer?) {
        let userVersion = pragmaUserVersion(db: db)
        if userVersion < 1 {
            execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS indexed_products (
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                name TEXT NOT NULL,
                brand TEXT NOT NULL,
                barcode TEXT NOT NULL,
                barcode_digits TEXT NOT NULL,
                stores_json TEXT NOT NULL,
                serving_description TEXT NOT NULL,
                ingredients_json TEXT NOT NULL,
                calories INTEGER NOT NULL,
                protein REAL NOT NULL,
                carbs REAL NOT NULL,
                fat REAL NOT NULL,
                fiber REAL NOT NULL,
                image_url TEXT NOT NULL,
                user_edited_at TEXT NOT NULL,
                last_updated_at TEXT NOT NULL,
                canonical_key TEXT NOT NULL
            );
            """)
            execute(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_indexed_products_barcode_digits ON indexed_products(barcode_digits);")
            execute(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_indexed_products_canonical_key ON indexed_products(canonical_key);")
            execute(db: db, sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS indexed_products_fts USING fts5(
                id UNINDEXED,
                name,
                brand,
                barcode,
                stores,
                ingredients,
                canonical_key,
                tokenize='unicode61 remove_diacritics 2'
            );
            """)
            execute(db: db, sql: "PRAGMA user_version = 1;")
        }
    }

    private func execute(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static func execute(db: OpaquePointer?, sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static func pragmaUserVersion(db: OpaquePointer?) -> Int {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }

    private func bindText(_ value: String, to index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func encodedJSONArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private func decodedJSONArray(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    private func product(from statement: OpaquePointer?) -> Product? {
        guard let statement else { return nil }
        guard let source = ProductSource(rawValue: columnText(at: 1, in: statement)) else { return nil }

        let name = columnText(at: 2, in: statement)
        let brand = columnText(at: 3, in: statement)
        let barcode = columnText(at: 4, in: statement)
        let stores = decodedJSONArray(columnText(at: 5, in: statement))
        let serving = columnText(at: 6, in: statement)
        let ingredients = decodedJSONArray(columnText(at: 7, in: statement))
        let calories = Int(sqlite3_column_int64(statement, 8))
        let protein = sqlite3_column_double(statement, 9)
        let carbs = sqlite3_column_double(statement, 10)
        let fat = sqlite3_column_double(statement, 11)
        let fiber = sqlite3_column_double(statement, 12)
        let imageURL = URL(string: columnText(at: 13, in: statement).trimmingCharacters(in: .whitespacesAndNewlines))
        let userEditedAt = isoFormatter.date(from: columnText(at: 14, in: statement))
        let lastUpdatedAt = isoFormatter.date(from: columnText(at: 15, in: statement)) ?? .now
        let id = columnText(at: 0, in: statement)

        return Product(
            id: id,
            source: source,
            name: name,
            brand: brand,
            barcode: barcode,
            stores: stores,
            servingDescription: serving,
            ingredients: ingredients,
            nutrition: NutritionFacts(calories: calories, protein: protein, carbs: carbs, fat: fat, fiber: fiber),
            imageURL: imageURL,
            userEditedAt: userEditedAt,
            lastUpdatedAt: lastUpdatedAt
        )
    }

    private func columnText(at index: Int32, in statement: OpaquePointer?) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func buildFTSQuery(from text: String) -> String {
        let tokens = normalizedIndexText(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    private func normalizedIndexText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
