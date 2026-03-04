# Thistle

Thistle is a personal iOS nutrition app concept that combines:

- Fig-style ingredient compatibility and diet scoring
- MyFitnessPal-style calories, macros, logging, and custom meals

This repo currently contains a SwiftUI prototype with:

- live product search and barcode lookup against Open Food Facts
- disk-backed persistence for goals, logs, meals, usage history, and cached products
- seeded sample products layered on top of the cached catalog

## Current v1 scope

- Search packaged foods by name
- Search local cache plus the online catalog
- Scan or manually enter a barcode
- Rate foods against a diet profile, starting with Whole30
- Highlight flagged ingredients with red/yellow/green treatment
- Set calorie, protein, carb, and fat goals
- Log foods and saved meals into the daily diary
- Build custom meals from products and aggregate nutrition totals

## Tech choices

- SwiftUI app scaffolded with XcodeGen
- In-memory app store using Swift Observation
- Extensible diet rules engine based on ingredient pattern matching
- Sample product catalog with store metadata
- Open Food Facts as the default free barcode + ingredients + nutriments source
- JSON persistence in Application Support for offline-ish cached reuse

## Open the project

```bash
xcodegen generate
open Thistle.xcodeproj
```

## Recommended next steps

1. Replace sample products with a UPC/product API plus local persistence.
2. Add USDA FoodData Central as an optional second source for broader branded-food fallback when you have an API key.
3. Move the diet engine to structured rule definitions instead of hardcoded patterns.
4. Add HealthKit import/export and better serving size normalization.
5. Add store-aware ranking and recipe search alongside packaged products.
