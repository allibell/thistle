import Foundation

struct IngredientAnalyzer {
    func analyze(
        product: Product,
        for diet: DietProfile?,
        restrictions: Set<DietaryRestriction> = []
    ) -> ProductAnalysis {
        guard diet != nil || !restrictions.isEmpty else {
            return ProductAnalysis(
                rating: .green,
                summary: "No diet or ingredient restrictions are selected.",
                flags: []
            )
        }

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

        var analyses: [ProductAnalysis] = []
        if let diet {
            analyses.append(analyze(product: product, for: diet))
        }
        analyses.append(contentsOf: restrictions.sorted { $0.rawValue < $1.rawValue }.map {
            analyze(product: product, for: $0)
        })

        let flags = analyses.flatMap(\.flags)
        let rating: ComplianceRating
        if analyses.contains(where: { $0.rating == .red }) {
            rating = .red
        } else if analyses.contains(where: { $0.rating == .yellow }) {
            rating = .yellow
        } else {
            rating = .green
        }

        let preferenceCount = (diet == nil ? 0 : 1) + restrictions.count
        let summary: String
        switch rating {
        case .red:
            summary = "One or more ingredients conflict with your selected diet preferences."
        case .yellow:
            summary = "No hard blockers found, but some ingredients need a closer look."
        case .green:
            summary = preferenceCount == 1
                ? "Ingredients look compatible with your selected diet preference."
                : "Ingredients look compatible with all selected diet preferences."
        }
        return ProductAnalysis(rating: rating, summary: summary, flags: flags)
    }

    private func analyze(product: Product, for diet: DietProfile) -> ProductAnalysis {
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

    private func analyze(product: Product, for restriction: DietaryRestriction) -> ProductAnalysis {
        switch restriction {
        case .glutenFree:
            return basicProfile(
                product: product,
                avoidTerms: [
                    "wheat", "barley", "rye", "triticale", "malt extract", "malt flavor",
                    "malt vinegar", "brewer's yeast", "brewers yeast"
                ],
                cautionTerms: ["oat", "oats"],
                profileName: restriction.rawValue
            )
        case .dairyFree:
            return basicProfile(
                product: product,
                avoidTerms: ["milk", "whey", "casein", "caseinate", "cheese", "butter", "cream", "lactose", "yogurt", "yoghurt", "ghee"],
                cautionTerms: [],
                profileName: restriction.rawValue
            )
        case .eggFree:
            return basicProfile(
                product: product,
                avoidTerms: ["egg", "eggs", "albumen", "mayonnaise", "meringue"],
                cautionTerms: [],
                profileName: restriction.rawValue
            )
        case .soyFree:
            return basicProfile(
                product: product,
                avoidTerms: ["soy", "soybean", "soya", "edamame", "tofu", "tempeh", "miso"],
                cautionTerms: [],
                profileName: restriction.rawValue
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
            if let match = avoidTerms.first(where: {
                ingredientMatches($0, in: ingredient, profileName: profileName)
                    && !isRestrictionFalsePositive(
                    term: $0,
                    ingredient: ingredient,
                    profileName: profileName
                )
            }) {
                flags.append(
                    IngredientFlag(
                        ingredient: ingredient.capitalized,
                        severity: .avoid,
                        reason: "Contains \(match), which conflicts with \(profileName)."
                    )
                )
            } else if let match = cautionTerms.first(where: {
                ingredientMatches($0, in: ingredient, profileName: profileName)
            }) {
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

    private func isRestrictionFalsePositive(
        term: String,
        ingredient: String,
        profileName: String
    ) -> Bool {
        switch profileName {
        case DietaryRestriction.dairyFree.rawValue:
            if term == "milk" {
                return ["almond", "cashew", "coconut", "oat", "rice", "soy", "hemp", "pea"]
                    .contains(where: { ingredient.contains("\($0) milk") })
            }
            if term == "butter" {
                return ["almond", "cashew", "cocoa", "coconut", "peanut", "sunflower", "apple"]
                    .contains(where: { ingredient.contains("\($0) butter") })
            }
            if term == "cream" {
                return ["cashew", "coconut", "oat", "soy"]
                    .contains(where: { ingredient.contains("\($0) cream") })
            }
            return false
        case DietaryRestriction.eggFree.rawValue:
            return term == "egg" && ingredient.contains("eggplant")
        default:
            return false
        }
    }

    private func ingredientMatches(_ term: String, in ingredient: String, profileName: String) -> Bool {
        guard DietaryRestriction(rawValue: profileName) != nil else {
            return ingredient.contains(term)
        }
        guard !term.contains(" "), !term.contains("'") else {
            return ingredient.contains(term)
        }
        let words = ingredient.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return words.contains(term)
    }
}
