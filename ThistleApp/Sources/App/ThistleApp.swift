import SwiftUI
import CoreText

private enum FontRegistry {
    static func registerBundledFonts() {
        let extensions = ["ttf", "otf", "ttc"]
        for fileExtension in extensions {
            let fontURLs = Bundle.main.urls(forResourcesWithExtension: fileExtension, subdirectory: nil) ?? []
            for url in fontURLs {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}

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
