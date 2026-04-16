import Foundation

enum SecureConfig {
    private static let placeholderFragments = [
        "YOUR_",
        "REPLACE",
        "REDACTED",
        "SET_VIA",
        "PUT_",
        "TODO"
    ]

    static func requiredSecret(named key: String) -> String? {
        if let envValue = ProcessInfo.processInfo.environment[key],
           isValidSecret(envValue) {
            return envValue
        }

        if let plistValue = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           isValidSecret(plistValue) {
            return plistValue
        }

        return nil
    }

    private static func isValidSecret(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let upper = trimmed.uppercased()
        return !placeholderFragments.contains { upper.contains($0) }
    }
}
