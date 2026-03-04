Place custom font files here and add them to the `Thistle` target resources in Xcode.

Recommended files for title font experiments:
- `BitcountInk-Regular.ttf` (or `.otf`)
- `Nabla-Regular.ttf` (or `.otf`)
- `UnicaOne-Regular.ttf` (or `.otf`)

After adding files, rebuild the app. The app registers bundled fonts at startup via `FontRegistry.registerBundledFonts()`.
