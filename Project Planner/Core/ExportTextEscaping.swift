//
//  ExportTextEscaping.swift
//  Project Planner
//
//  One encoder for user text that is about to enter HTML, an email header, or a spreadsheet cell.
//

import Foundation

nonisolated enum ExportTextEscaping {
    /// Encodes `& < > " '` for HTML or XML text and attributes.
    /// Leaves an existing `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`, or numeric character reference alone.
    static func escapeHTML(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "&", let entityEnd = existingCharacterReferenceEnd(in: value, ampersand: index) {
                result.append(contentsOf: value[index..<entityEnd])
                index = entityEnd
                continue
            }
            switch value[index] {
            case "&":
                result.append("&amp;")
            case "<":
                result.append("&lt;")
            case ">":
                result.append("&gt;")
            case "\"":
                result.append("&quot;")
            case "'":
                result.append("&#39;")
            default:
                result.append(value[index])
            }
            index = value.index(after: index)
        }
        return result
    }

    /// HTML-escapes a URL that has already been assembled, for an href or src attribute.
    static func escapeHTMLAttributeURL(_ url: String) -> String {
        escapeHTML(url)
    }

    /// Builds `base?name=value&...`, percent-encoding each token, then HTML-escapes the whole URL.
    static func htmlQueryURL(absoluteBase: String, queryItems: [(String, String)]) -> String {
        let query = queryItems.map { name, value in
            percentEncodeURLToken(name) + "=" + percentEncodeURLToken(value)
        }.joined(separator: "&")
        let url = query.isEmpty ? absoluteBase : absoluteBase + "?" + query
        return escapeHTML(url)
    }

    /// Appends a percent-encoded token to a static URL prefix, then HTML-escapes the whole URL.
    static func htmlTokenURL(prefix: String, token: String) -> String {
        escapeHTML(prefix + percentEncodeURLToken(token))
    }

    /// Percent-encodes a query or path token. An existing `%HH` sequence is kept as-is.
    static func percentEncodeURLToken(_ value: String, extraAllowed: String = "") -> String {
        let extras = Set(extraAllowed)
        var result = ""
        result.reserveCapacity(value.count)
        var index = value.startIndex
        while index < value.endIndex {
            if let afterEscape = existingPercentEscapeEnd(in: value, percent: index) {
                result.append(contentsOf: value[index..<afterEscape])
                index = afterEscape
                continue
            }
            let character = value[index]
            if isUnreservedURLCharacter(character) || extras.contains(character) {
                result.append(character)
            } else {
                for byte in String(character).utf8 {
                    result.append(String(format: "%%%02X", byte))
                }
            }
            index = value.index(after: index)
        }
        return result
    }

    /// Collapses CR/LF so a name cannot start a second header, strips other ASCII controls, trims, and caps at 180 characters.
    static func sanitizeEmailSubject(_ value: String) -> String {
        sanitizeHeaderText(value, maximumCharacters: 180)
    }

    /// Same header rules as a subject, capped at 80 characters.
    static func sanitizeFromDisplayName(_ value: String) -> String {
        sanitizeHeaderText(value, maximumCharacters: 80)
    }

    /// Reply-To is an address. Trim and remove CR/LF. Does not rewrite the address.
    static func sanitizeReplyToAddress(_ value: String) -> String {
        var cleaned = ""
        cleaned.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            if scalar == "\u{000D}" || scalar == "\u{000A}" { continue }
            cleaned.unicodeScalars.append(scalar)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prefixes one apostrophe when a string cell would otherwise be read as a formula.
    static func spreadsheetFormulaPrefix(_ value: String) -> String {
        guard let first = value.first, formulaLeaders.contains(first) else { return value }
        return "'" + value
    }

    /// Formula prefix, then standard CSV quoting for comma, quote, or newline.
    static func csvField(_ value: String) -> String {
        let guarded = spreadsheetFormulaPrefix(value)
        let needsQuotes = guarded.contains { character in
            character == "," || character == "\"" || character == "\n" || character == "\r"
        }
        if needsQuotes {
            return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return guarded
    }

    static func joinCSV(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",")
    }

    private static let formulaLeaders: Set<Character> = ["=", "+", "-", "@", "\t", "\r", "\n"]

    private static func sanitizeHeaderText(_ value: String, maximumCharacters: Int) -> String {
        var cleaned = ""
        cleaned.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            if scalar == "\u{000D}" || scalar == "\u{000A}" {
                cleaned.append(" ")
            } else if scalar.value < 0x20 || scalar.value == 0x7F {
                continue
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters else { return trimmed }
        return String(trimmed.prefix(maximumCharacters))
    }

    private static func existingCharacterReferenceEnd(in value: String, ampersand: String.Index) -> String.Index? {
        let afterAmpersand = value.index(after: ampersand)
        guard afterAmpersand < value.endIndex else { return nil }
        if value[afterAmpersand] == "#" {
            return numericCharacterReferenceEnd(in: value, hash: afterAmpersand)
        }
        for name in ["amp", "lt", "gt", "quot"] {
            let token = name + ";"
            if value[afterAmpersand...].hasPrefix(token) {
                return value.index(afterAmpersand, offsetBy: token.count)
            }
        }
        return nil
    }

    private static func numericCharacterReferenceEnd(in value: String, hash: String.Index) -> String.Index? {
        var cursor = value.index(after: hash)
        guard cursor < value.endIndex else { return nil }
        if value[cursor] == "x" || value[cursor] == "X" {
            cursor = value.index(after: cursor)
            let digitsStart = cursor
            while cursor < value.endIndex, isASCIIHexDigit(value[cursor]) {
                cursor = value.index(after: cursor)
            }
            guard cursor > digitsStart, cursor < value.endIndex, value[cursor] == ";" else { return nil }
            return value.index(after: cursor)
        }
        let digitsStart = cursor
        while cursor < value.endIndex, isASCIIDigit(value[cursor]) {
            cursor = value.index(after: cursor)
        }
        guard cursor > digitsStart, cursor < value.endIndex, value[cursor] == ";" else { return nil }
        return value.index(after: cursor)
    }

    private static func existingPercentEscapeEnd(in value: String, percent: String.Index) -> String.Index? {
        guard value[percent] == "%" else { return nil }
        let first = value.index(after: percent)
        guard first < value.endIndex else { return nil }
        let second = value.index(after: first)
        guard second < value.endIndex else { return nil }
        guard isASCIIHexDigit(value[first]), isASCIIHexDigit(value[second]) else { return nil }
        return value.index(after: second)
    }

    private static func isUnreservedURLCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        if scalar.value >= 65 && scalar.value <= 90 { return true }
        if scalar.value >= 97 && scalar.value <= 122 { return true }
        if scalar.value >= 48 && scalar.value <= 57 { return true }
        switch scalar.value {
        case 45, 46, 95, 126: // - . _ ~
            return true
        default:
            return false
        }
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return scalar.value >= 48 && scalar.value <= 57
    }

    private static func isASCIIHexDigit(_ character: Character) -> Bool {
        if isASCIIDigit(character) { return true }
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return (scalar.value >= 65 && scalar.value <= 70) || (scalar.value >= 97 && scalar.value <= 102)
    }
}
