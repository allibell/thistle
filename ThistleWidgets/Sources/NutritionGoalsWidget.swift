import SwiftUI
import WidgetKit

struct NutritionGoalsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetNutritionSnapshot
}

struct NutritionGoalsProvider: TimelineProvider {
    func placeholder(in context: Context) -> NutritionGoalsEntry {
        NutritionGoalsEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NutritionGoalsEntry) -> Void) {
        completion(NutritionGoalsEntry(date: .now, snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NutritionGoalsEntry>) -> Void) {
        let entry = NutritionGoalsEntry(date: .now, snapshot: loadSnapshot())
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func loadSnapshot() -> WidgetNutritionSnapshot {
        guard let defaults = UserDefaults(suiteName: WidgetNutritionSnapshot.appGroupID),
              let data = defaults.data(forKey: WidgetNutritionSnapshot.storageKey) else {
            return .placeholder
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(WidgetNutritionSnapshot.self, from: data)) ?? .placeholder
    }
}

struct NutritionGoalsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NutritionGoalsEntry

    private var shownMetrics: [WidgetNutritionMetric] {
        switch family {
        case .systemLarge:
            return WidgetNutritionMetric.allCases
        default:
            return [.calories, .protein, .carbs, .fat]
        }
    }

    var body: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content
                .containerBackground(for: .widget) {
                    widgetBackground
                }
        } else {
            content
                .background(widgetBackground)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Today")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Text("Nutrition Goals")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            ForEach(shownMetrics) { metric in
                NutritionProgressRow(
                    title: metric.title,
                    current: metric.value(in: entry.snapshot).consumed,
                    goal: metric.value(in: entry.snapshot).goal,
                    currentText: metric.formatted(metric.value(in: entry.snapshot).consumed),
                    goalText: metric.formatted(metric.value(in: entry.snapshot).goal),
                    tint: color(for: metric)
                )
            }
        }
        .padding(14)
    }

    private var widgetBackground: some View {
        LinearGradient(
            colors: [
                Color(hex: "#F7F5F3"),
                Color(hex: "#EEE9E5")
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func color(for metric: WidgetNutritionMetric) -> Color {
        switch metric {
        case .calories: return Color(hex: "#2CA44F")
        case .protein: return Color(hex: "#D75CB8")
        case .carbs: return Color(hex: "#B42FC2")
        case .fat: return Color(hex: "#6BC045")
        case .fiber: return Color(hex: "#D28B2A")
        }
    }
}

struct NutritionProgressRow: View {
    let title: String
    let current: Double
    let goal: Double
    let currentText: String
    let goalText: String
    let tint: Color

    private var progress: Double {
        guard goal > 0 else { return 0 }
        return min(current / goal, 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .frame(width: 58, alignment: .leading)
                ProgressBar(progress: progress, tint: tint)
                Text("\(currentText)/\(goalText)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }
}

struct ProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.8), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(width, 2))
            }
        }
        .frame(height: 8)
    }
}

struct NutritionGoalsWidget: Widget {
    static let kind = "NutritionGoalsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NutritionGoalsProvider()) { entry in
            NutritionGoalsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Nutrition Goal Bars")
        .description("Track today's calories and macro goal progress at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct ThistleWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NutritionGoalsWidget()
    }
}

private extension Color {
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&int)

        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
