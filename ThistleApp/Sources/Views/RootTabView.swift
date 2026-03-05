import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TabView(selection: $store.selectedTab) {
            NavigationStack {
                SearchView()
            }
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }
            .tag(AppTab.search)

            NavigationStack {
                ScanView()
            }
            .tabItem {
                Label("Scan", systemImage: "barcode.viewfinder")
            }
            .tag(AppTab.scan)

            NavigationStack {
                DiaryView()
            }
            .tabItem {
                Label("Diary", systemImage: "list.clipboard")
            }
            .tag(AppTab.diary)

            NavigationStack {
                MealsView()
            }
            .tabItem {
                Label("Meals", systemImage: "fork.knife")
            }
            .tag(AppTab.meals)

            NavigationStack {
                GoalsView()
            }
            .tabItem {
                Label("Goals", systemImage: "target")
            }
            .tag(AppTab.goals)
        }
        .tint(ThistleTheme.primaryGreen)
        .background(ThistleTheme.canvas.ignoresSafeArea())
    }
}
