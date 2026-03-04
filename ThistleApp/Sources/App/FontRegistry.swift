import Foundation
import CoreText

enum FontRegistry {
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

