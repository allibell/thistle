import SwiftUI

struct RatingBadge: View {
    var rating: ComplianceRating

    var body: some View {
        Text(rating.title.uppercased())
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(rating.color.gradient, in: Capsule())
    }
}

struct RatingExplanationView: View {
    var analysis: ProductAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Why this rating")
                    .font(.headline)
                Spacer()
                RatingBadge(rating: analysis.rating)
            }

            Text(analysis.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if analysis.flags.isEmpty {
                Label(
                    analysis.rating == .yellow ? "The explanation above is the recorded reason; no ingredient-specific flags were recorded." : "No specific ingredient concerns were recorded.",
                    systemImage: analysis.rating == .yellow ? "questionmark.circle" : "checkmark.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                ForEach(analysis.flags) { flag in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(flag.severity.color)
                            .frame(width: 9, height: 9)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(flag.ingredient)
                                .font(.subheadline.weight(flag.severity.fontWeight))
                                .foregroundStyle(flag.severity.color)
                            Text(flag.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct FoodComponentTreeView: View {
    var components: [FoodItemComponent]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What’s in it")
                .font(.headline)
            ForEach(components) { component in
                FoodComponentRow(component: component)
            }
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct FoodComponentRow: View {
    var component: FoodItemComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: component.components.isEmpty ? "circle.fill" : "square.stack.3d.up.fill")
                    .font(component.components.isEmpty ? .system(size: 7) : .caption)
                    .foregroundStyle(component.analysis.rating.color)
                    .frame(width: 16, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(component.title)
                        .font(.subheadline.weight(.semibold))
                    Text("\(component.servingText) · \(component.nutrition.calories) cal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(component.analysis.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RatingBadge(rating: component.analysis.rating)
                    .scaleEffect(0.82, anchor: .topTrailing)
            }

            if !component.components.isEmpty {
                FoodComponentTreeView(components: component.components)
                    .padding(.leading, 16)
            }
        }
    }
}

struct MacroSummaryView: View {
    var nutrition: NutritionFacts

    var body: some View {
        HStack(spacing: 10) {
            macroPill(title: "Cal", value: "\(nutrition.calories)")
            macroPill(title: "P", value: "\(nutrition.protein.formatted(.number.precision(.fractionLength(0))))g")
            macroPill(title: "C", value: "\(nutrition.carbs.formatted(.number.precision(.fractionLength(0))))g")
            macroPill(title: "F", value: "\(nutrition.fat.formatted(.number.precision(.fractionLength(0))))g")
            macroPill(title: "Fi", value: "\(nutrition.fiber.formatted(.number.precision(.fractionLength(0))))g")
        }
    }

    private func macroPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct IngredientsSection: View {
    var product: Product
    var analysis: ProductAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ingredients")
                .font(.headline)

            ForEach(product.ingredients, id: \.self) { ingredient in
                let matchedFlag = analysis.flags.first { flag in
                    flag.ingredient.localizedCaseInsensitiveContains(ingredient)
                        || ingredient.localizedCaseInsensitiveContains(flag.ingredient)
                }
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill((matchedFlag?.severity.color ?? ThistleTheme.primaryGreen).opacity(0.9))
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ingredient)
                            .fontWeight(matchedFlag?.severity.fontWeight ?? .regular)
                            .foregroundStyle(matchedFlag?.severity.color ?? .primary)
                        if let matchedFlag {
                            Text(matchedFlag.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct ProductCard: View {
    var product: Product
    var analysis: ProductAnalysis
    var isFavorite: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.name)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text(product.brand)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("Favorited")
                        }
                        if product.isUserEdited {
                            Text("USER EDITED")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(ThistleTheme.warning.opacity(0.2), in: Capsule())
                                .foregroundStyle(ThistleTheme.warning)
                        }
                    }
                }
                Spacer()
                RatingBadge(rating: analysis.rating)
            }

            Text(analysis.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            MacroSummaryView(nutrition: product.nutrition)

            if !analysis.flags.isEmpty {
                Text(analysis.flags.map(\.ingredient).joined(separator: ", "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(analysis.rating.color)
                    .lineLimit(2)
            }
        }
        .padding()
        .background(ThistleTheme.cardElevated, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(ThistleTheme.blossomPurple.opacity(0.05), lineWidth: 0.75)
        }
        .shadow(color: .clear, radius: 0, y: 0)
    }
}

extension View {
    func thistleNavigationTitle(_ title: String) -> some View {
        navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(ThistleTheme.blossomPurple)
                        .padding(.top, 6)
                }
            }
    }
}
