import Foundation

struct PhoneNormalizer {
    static func normalize(_ raw: String, defaultRegion: String = "TR") -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }

        if digits.hasPrefix("00") {
            digits.removeFirst(2)
            return "+" + digits
        }

        if trimmed.hasPrefix("+") {
            return "+" + digits
        }

        if defaultRegion == "TR" {
            if digits.count == 12, digits.hasPrefix("90") {
                return "+" + digits
            }
            if digits.count == 11, digits.hasPrefix("0") {
                digits.removeFirst()
                return "+90" + digits
            }
            if digits.count == 10 {
                return "+90" + digits
            }
        }

        return digits
    }
}

struct EmailNormalizer {
    static func normalize(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? nil : value
    }
}

struct NameNormalizer {
    private static let turkishMap: [Character: Character] = [
        "ç": "c", "Ç": "c",
        "ğ": "g", "Ğ": "g",
        "ı": "i", "İ": "i",
        "ö": "o", "Ö": "o",
        "ş": "s", "Ş": "s",
        "ü": "u", "Ü": "u"
    ]

    static func normalize(_ raw: String) -> String {
        var mapped = String(raw.map { turkishMap[$0] ?? $0 })
        mapped = mapped.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr_TR"))
        mapped = mapped.lowercased(with: Locale(identifier: "tr_TR"))

        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        mapped = String(mapped.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : " " })

        return mapped
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
    }

    static func fullName(_ contact: ContactSnapshot) -> String {
        normalize([contact.givenName, contact.middleName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " "))
    }
}

struct CompanyNormalizer {
    static func normalize(_ raw: String) -> String {
        NameNormalizer.normalize(raw)
            .replacingOccurrences(of: " anonim sirketi", with: "")
            .replacingOccurrences(of: " limited sirketi", with: "")
            .replacingOccurrences(of: " ltd sti", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

struct StringSimilarity {
    static func normalizedLevenshtein(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }

        let left = Array(a)
        let right = Array(b)
        var previous = Array(0...right.count)

        for (i, lc) in left.enumerated() {
            var current = [i + 1]
            for (j, rc) in right.enumerated() {
                let insertion = current[j] + 1
                let deletion = previous[j + 1] + 1
                let substitution = previous[j] + (lc == rc ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }

        let distance = previous[right.count]
        return 1 - Double(distance) / Double(max(left.count, right.count))
    }
}
