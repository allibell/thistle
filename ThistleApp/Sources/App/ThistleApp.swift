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

private enum AppDeepLink {
    case scan

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "thistle" else { return nil }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host == "scan" || path == "/scan" {
            self = .scan
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let tabValue = components?.queryItems?.first(where: { $0.name.lowercased() == "tab" })?.value?.lowercased()
        if tabValue == "scan" {
            self = .scan
            return
        }

        return nil
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
                .onOpenURL { url in
                    guard let deepLink = AppDeepLink(url: url) else { return }
                    switch deepLink {
                    case .scan:
                        store.selectedTab = .scan
                    }
                }
        }
    }
}
