import Foundation

enum SampleData {
    static let products: [Product] = [
        Product(
            name: "Chicken Apple Sausage",
            brand: "Applegate",
            barcode: "025317005887",
            stores: ["Whole Foods", "Safeway"],
            servingDescription: "1 link",
            ingredients: ["Chicken", "Dried Apples", "Water", "Sea Salt", "Spices"],
            nutrition: NutritionFacts(calories: 140, protein: 11, carbs: 4, fat: 9)
        ),
        Product(
            name: "Cauliflower Gnocchi",
            brand: "Trader Joe's",
            barcode: "00912731",
            stores: ["Trader Joe's"],
            servingDescription: "1 cup",
            ingredients: ["Cauliflower", "Cassava Flour", "Potato Starch", "Extra Virgin Olive Oil", "Sea Salt"],
            nutrition: NutritionFacts(calories: 140, protein: 3, carbs: 22, fat: 3)
        ),
        Product(
            name: "Protein Bar Chocolate Peanut Butter",
            brand: "FitFuel",
            barcode: "850123456789",
            stores: ["Whole Foods", "Safeway"],
            servingDescription: "1 bar",
            ingredients: ["Pea Protein", "Peanuts", "Brown Rice Syrup", "Chocolate", "Natural Flavors"],
            nutrition: NutritionFacts(calories: 220, protein: 20, carbs: 23, fat: 8)
        ),
        Product(
            name: "Coconut Yogurt Vanilla",
            brand: "Cultured Co.",
            barcode: "860000112233",
            stores: ["Whole Foods"],
            servingDescription: "3/4 cup",
            ingredients: ["Coconut Milk", "Tapioca Starch", "Vanilla", "Cane Sugar", "Live Cultures"],
            nutrition: NutritionFacts(calories: 180, protein: 2, carbs: 17, fat: 12)
        ),
        Product(
            name: "Wild Salmon Burger",
            brand: "North Shore",
            barcode: "761234567890",
            stores: ["Whole Foods", "Safeway"],
            servingDescription: "1 patty",
            ingredients: ["Salmon", "Onion", "Garlic", "Black Pepper", "Sea Salt"],
            nutrition: NutritionFacts(calories: 170, protein: 20, carbs: 1, fat: 9)
        ),
        Product(
            name: "Almond Flour Crackers",
            brand: "Simple Mills",
            barcode: "856069005162",
            stores: ["Whole Foods", "Safeway"],
            servingDescription: "17 crackers",
            ingredients: ["Almond Flour", "Sunflower Seeds", "Flax Seeds", "Cassava", "Rosemary Extract"],
            nutrition: NutritionFacts(calories: 150, protein: 3, carbs: 17, fat: 8)
        )
    ]
}
