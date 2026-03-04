import SwiftUI

@main
struct ThistleApp: App {
    @StateObject private var store = AppStore()

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
        }
    }
}
