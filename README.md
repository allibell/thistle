# Thistle

Thistle is a personal iOS nutrition app concept that combines:

- Fig-style ingredient compatibility and diet scoring
- MyFitnessPal-style calories, macros, logging, and custom meals

This repo currently contains a SwiftUI v1 prototype with in-memory data so the full core flow can be exercised without backend work.

## Current v1 scope

- Search packaged foods by name
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

## Open the project

```bash
xcodegen generate
open Thistle.xcodeproj
```

## Recommended next steps

1. Replace sample products with a UPC/product API plus local persistence.
2. Move the diet engine to structured rule definitions instead of hardcoded patterns.
3. Persist goals, logs, meals, and recent/frequent foods with SwiftData or SQLite.
4. Add HealthKit import/export and better serving size normalization.
5. Add store-aware ranking and recipe search alongside packaged products.
