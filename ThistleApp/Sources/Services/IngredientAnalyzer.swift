import Foundation

struct IngredientAnalyzer {
    func analyze(product: Product, for diet: DietProfile) -> ProductAnalysis {
        if !product.hasIngredientDetails {
            return ProductAnalysis(
                rating: .yellow,
                summary: "This entry is missing ingredients, so compatibility cannot be verified.",
                flags: [
                    IngredientFlag(
                        ingredient: "Missing ingredients",
                        severity: .caution,
                        reason: "No ingredient list is available for this product."
                    )
                ]
            )
        }

        switch diet {
        case .whole30:
            return analyzeWhole30(product: product)
        case .pescatarian:
            return basicProfile(
                product: product,
                avoidTerms: ["beef", "chicken", "pork", "gelatin", "turkey"],
                cautionTerms: ["natural flavors"],
                profileName: "pescatarian"
            )
        case .vegan:
            return basicProfile(
                product: product,
                avoidTerms: ["milk", "butter", "whey", "egg", "honey", "gelatin", "cheese"],
                cautionTerms: ["natural flavors"],
                profileName: "vegan"
            )
        case .keto:
            if product.nutrition.carbs > 15 {
                return ProductAnalysis(
                    rating: .yellow,
                    summary: "Higher carb count may not fit stricter keto targets.",
                    flags: [IngredientFlag(ingredient: "\(Int(product.nutrition.carbs))g carbs", severity: .caution, reason: "High carb serving")]
                )
            }
            return ProductAnalysis(rating: .green, summary: "Macro profile looks keto-friendly.", flags: [])
        case .paleo:
            return basicProfile(
                product: product,
                avoidTerms: ["soy", "corn", "maltodextrin", "cane sugar", "dextrose", "peanut"],
                cautionTerms: ["natural flavors", "sunflower lecithin"],
                profileName: "paleo"
            )
        }
    }

    private func analyzeWhole30(product: Product) -> ProductAnalysis {
        let avoidTerms = [
            "sugar", "cane sugar", "brown sugar", "corn syrup", "soy", "soybean",
            "maltodextrin", "dextrose", "rice bran", "whey", "milk", "cheese",
            "oat", "flour", "pea protein", "msg", "sulfite", "carrageenan"
        ]
        let cautionTerms = ["natural flavors", "gum", "lecithin"]
        return basicProfile(
            product: product,
            avoidTerms: avoidTerms,
            cautionTerms: cautionTerms,
            profileName: "Whole30"
        )
    }

    private func basicProfile(
        product: Product,
        avoidTerms: [String],
        cautionTerms: [String],
        profileName: String
    ) -> ProductAnalysis {
        let loweredIngredients = product.ingredients.map { $0.lowercased() }
        var flags: [IngredientFlag] = []

        for ingredient in loweredIngredients {
            if let match = avoidTerms.first(where: { ingredient.contains($0) }) {
                flags.append(
                    IngredientFlag(
                        ingredient: ingredient.capitalized,
                        severity: .avoid,
                        reason: "Contains \(match), which conflicts with \(profileName)."
                    )
                )
            } else if let match = cautionTerms.first(where: { ingredient.contains($0) }) {
                flags.append(
                    IngredientFlag(
                        ingredient: ingredient.capitalized,
                        severity: .caution,
                        reason: "Contains \(match), which may need a closer look."
                    )
                )
            }
        }

        let rating: ComplianceRating
        let summary: String
        if flags.contains(where: { $0.severity == .avoid }) {
            rating = .red
            summary = "One or more ingredients clearly conflict with this diet."
        } else if flags.contains(where: { $0.severity == .caution }) {
            rating = .yellow
            summary = "No hard blockers found, but some ingredients deserve caution."
        } else {
            rating = .green
            summary = "Ingredients look compatible with this diet."
        }

        return ProductAnalysis(rating: rating, summary: summary, flags: flags)
    }
}
