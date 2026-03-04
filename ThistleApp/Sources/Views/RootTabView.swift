import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                SearchView()
            }
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }

            NavigationStack {
                ScanView()
            }
            .tabItem {
                Label("Scan", systemImage: "barcode.viewfinder")
            }

            NavigationStack {
                DiaryView()
            }
            .tabItem {
                Label("Diary", systemImage: "list.clipboard")
            }

            NavigationStack {
                MealsView()
            }
            .tabItem {
                Label("Meals", systemImage: "fork.knife")
            }

            NavigationStack {
                GoalsView()
            }
            .tabItem {
                Label("Goals", systemImage: "target")
            }
        }
        .tint(.green)
    }
}
