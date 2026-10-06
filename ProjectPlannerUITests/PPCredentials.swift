import XCTest

/// Reads account secrets from the test runner environment.
/// `xcodebuild` forwards `TEST_RUNNER_X` to the runner as `X`. Both names are accepted.
enum PPCredentials {
    static func required(_ key: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let env = ProcessInfo.processInfo.environment
        for name in [key, "TEST_RUNNER_\(key)"] {
            if let value = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        XCTFail(
            "Missing \(key). Pass TEST_RUNNER_\(key) to xcodebuild (the runner receives it as \(key)).",
            file: file,
            line: line
        )
        return ""
    }

    static var adminEmail: String { required("ADMIN_EMAIL") }
    static var adminPassword: String { required("ADMIN_PASSWORD") }
    static var managerEmail: String { required("MANAGER_EMAIL") }
    static var managerPassword: String { required("MANAGER_PASSWORD") }
    static var operativeEmail: String { required("OPERATIVE_EMAIL") }
    static var operativePassword: String { required("OPERATIVE_PASSWORD") }

    static func email(for role: String) -> String {
        switch role {
        case "admin": return adminEmail
        case "manager": return managerEmail
        case "operative": return operativeEmail
        default:
            XCTFail("No credential mapping for role \(role)")
            return ""
        }
    }

    static func password(for role: String) -> String {
        switch role {
        case "admin": return adminPassword
        case "manager": return managerPassword
        case "operative": return operativePassword
        default:
            XCTFail("No credential mapping for role \(role)")
            return ""
        }
    }
}
