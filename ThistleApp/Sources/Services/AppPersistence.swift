import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

struct AppPersistence {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let widgetEncoder: JSONEncoder
    private let calendar: Calendar
    private let now: () -> Date

    init(
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folderURL = appSupport.appendingPathComponent("Thistle", isDirectory: true)
        fileURL = folderURL.appendingPathComponent("state.json")
        self.calendar = calendar
        self.now = now

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        widgetEncoder = JSONEncoder()
        widgetEncoder.dateEncodingStrategy = .iso8601
    }

    func load() -> PersistedAppState? {
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(PersistedAppState.self, from: data)
        } catch {
            return nil
        }
    }

    func save(_ state: PersistedAppState) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
            saveWidgetSnapshot(state)
        } catch {
            assertionFailure("Failed to save state: \(error.localizedDescription)")
        }
    }

    private func saveWidgetSnapshot(_ state: PersistedAppState) {
        let snapshotDate = now()
        let todayNutrition = nutritionForCurrentDay(in: state.loggedFoods, now: snapshotDate)
        let snapshot = WidgetNutritionSnapshot(
            updatedAt: snapshotDate,
            calories: WidgetNutritionSnapshot.MetricProgress(
                consumed: Double(todayNutrition.calories),
                goal: Double(state.goals.calories)
            ),
            protein: WidgetNutritionSnapshot.MetricProgress(consumed: todayNutrition.protein, goal: state.goals.protein),
            carbs: WidgetNutritionSnapshot.MetricProgress(consumed: todayNutrition.carbs, goal: state.goals.carbs),
            fat: WidgetNutritionSnapshot.MetricProgress(consumed: todayNutrition.fat, goal: state.goals.fat),
            fiber: WidgetNutritionSnapshot.MetricProgress(consumed: todayNutrition.fiber, goal: state.goals.fiber)
        )

        do {
            guard let defaults = UserDefaults(suiteName: WidgetNutritionSnapshot.appGroupID) else { return }
            let encodedSnapshot = try widgetEncoder.encode(snapshot)
            defaults.set(encodedSnapshot, forKey: WidgetNutritionSnapshot.storageKey)
#if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
#endif
        } catch {
            assertionFailure("Failed to save widget snapshot: \(error.localizedDescription)")
        }
    }

    private func nutritionForCurrentDay(in entries: [LoggedFood], now: Date) -> NutritionFacts {
        entries
            .filter { calendar.isDate($0.loggedAt, inSameDayAs: now) }
            .reduce(.zero) { partial, entry in
                partial + entry.nutrition
            }
    }
}
