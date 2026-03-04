import Foundation

enum BarcodeNormalizer {
    static func digitsOnly(from raw: String) -> String {
        raw.filter(\.isNumber)
    }

    static func variants(for raw: String) -> [String] {
        let digits = digitsOnly(from: raw)
        guard !digits.isEmpty else { return [] }

        var ordered: [String] = []
        func append(_ value: String) {
            guard !value.isEmpty, !ordered.contains(value) else { return }
            ordered.append(value)
        }

        append(digits)
        append(String(digits.drop(while: { $0 == "0" })))

        if digits.count == 12 {
            append("0" + digits)
            append("00" + digits)
        } else if digits.count == 13 {
            append(String(digits.dropFirst()))
            append("0" + digits)
        } else if digits.count == 14 {
            append(String(digits.dropFirst()))
            append(String(digits.dropFirst(2)))
        }

        return ordered
    }
}
