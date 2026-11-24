import Foundation

/// UK postcode text for display, typing and lookups (owner bug 24 Nov: a stored "Sw1× 9Hr").
///
/// Display and lookup only: nothing here writes to Firestore. A stored look-alike of the letter x (×, ✕, ✖, ⨯, the
/// Cyrillic х / Х) is read as x, and a UK postcode is shown in upper case with one space ("SW1X 9HR"). Only a person's
/// own save of the postcode field writes the corrected value. Same behaviour as web `lib/maps/ukPostcode.ts`.
nonisolated enum UKPostcodeText {
    private static let lookalikes: [Character: Character] = [
        "\u{00D7}": "x", "\u{2715}": "x", "\u{2716}": "x", "\u{2A2F}": "x", "\u{0445}": "x", "\u{0425}": "X"
    ]

    nonisolated(unsafe) private static let wholePostcode = try! NSRegularExpression(
        pattern: "^[A-Z]{1,2}[0-9][A-Z0-9]?[0-9][A-Z]{2}$",
        options: [.caseInsensitive]
    )

    /// UK postcodes inside free text, x look-alikes allowed in their letter places (L = a letter or a look-alike).
    nonisolated(unsafe) private static let postcodeInText: NSRegularExpression = {
        let l = "A-Za-z\u{00D7}\u{2715}\u{2716}\u{2A2F}\u{0445}\u{0425}"
        let pattern = "(?<![\(l)0-9])([\(l)]{1,2}[0-9][\(l)0-9]?\\s*[0-9][\(l)]{2})(?![\(l)0-9])"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// The text with every look-alike of x read as the letter x.
    static func lookalikesToX(_ value: String) -> String {
        String(value.map { lookalikes[$0] ?? $0 })
    }

    /// "sw1x9hr" / "Sw1× 9Hr" → "SW1X 9HR" (the inward code is always the last three characters).
    static func formatUK(_ value: String) -> String {
        let compact = lookalikesToX(value).filter { !$0.isWhitespace }.uppercased()
        guard compact.count >= 5 else { return compact }
        return "\(compact.dropLast(3)) \(compact.suffix(3))"
    }

    /// Whether the text (any case or spacing, look-alikes read as x) is one whole UK postcode.
    static func isUK(_ value: String) -> Bool {
        let compact = lookalikesToX(value).filter { !$0.isWhitespace }
        let range = NSRange(compact.startIndex..., in: compact)
        return wholePostcode.firstMatch(in: compact, options: [], range: range) != nil
    }

    /// A stored postcode field as shown: a UK postcode "SW1X 9HR"; anything else trimmed, look-alikes read as x.
    static func display(_ value: String?) -> String {
        let text = lookalikesToX(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return isUK(text) ? formatUK(text) : text
    }

    /// The postcode field while typing: look-alikes become x and letters upper case; spaces kept as typed.
    static func inputValue(_ value: String) -> String {
        lookalikesToX(value).uppercased()
    }

    /// A stored address with every UK postcode in it shown as "SW1X 9HR". Other text is left as stored.
    static func tidyAddress(_ text: String) -> String {
        var result = text
        let matches = postcodeInText.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(range, with: formatUK(String(result[range])))
        }
        return result
    }
}
