import SwiftUI

enum ThistleTheme {
    static let canvas = Color(hex: "#F2F1F0")
    static let card = Color(hex: "#EBE9E7")
    static let cardElevated = Color.white.opacity(0.92)
    static let primaryGreen = Color(hex: "#2CA44F")
    static let stemGreen = Color(hex: "#6BC045")
    static let blossomPurple = Color(hex: "#B42FC2")
    static let blossomPink = Color(hex: "#D75CB8")
    static let blossomDeep = Color(hex: "#7E1BA6")
    static let warning = Color(hex: "#D28B2A")
    static let danger = Color(hex: "#C93F5A")
    static let wordmarkGradient = LinearGradient(
        colors: [blossomPink, blossomPurple, blossomDeep],
        startPoint: .leading,
        endPoint: .trailing
    )
}

extension Color {
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&int)

        let r, g, b: UInt64
        switch trimmed.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}
