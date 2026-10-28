import XCTest
@testable import Project_Planner

/// The shared parity fixture: web `lib/canonical/parity-fixture.json`, copied here with each packed script.
/// Every case calls the named rulebook function through `CanonicalBusinessEngine` and must return
/// `expected` exactly, the same check web's `canonical.test.ts` runs. A failure here means iOS and web
/// would disagree on that case.
final class CanonicalParityFixtureTests: XCTestCase {
    private struct Case {
        let name: String
        let function: String
        let arguments: [Any]
        let expected: Any
    }

    private func loadCases() throws -> [Case] {
        let bundle = Bundle(for: CanonicalParityFixtureTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "CanonicalParityFixture", withExtension: "json"),
            "CanonicalParityFixture.json is missing from the test bundle"
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let rows = try XCTUnwrap(root["cases"] as? [[String: Any]])
        return try rows.map { row in
            Case(
                name: try XCTUnwrap(row["name"] as? String),
                function: try XCTUnwrap(row["function"] as? String),
                arguments: try XCTUnwrap(row["args"] as? [Any]),
                expected: row["expected"] ?? NSNull()
            )
        }
    }

    /// JSON text with sorted keys, so two equal values compare equal regardless of key order.
    private func canonicalJSON(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "<not JSON>"
    }

    func testEveryCaseMatchesTheSharedExpectation() throws {
        let cases = try loadCases()
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            guard let actual = CanonicalBusinessEngine.callJSON(item.function, arguments: item.arguments) else {
                XCTFail("\(item.function) did not run in the packed script — \(item.name)")
                continue
            }
            XCTAssertEqual(
                canonicalJSON(actual),
                canonicalJSON(item.expected),
                "\(item.function): \(item.name)"
            )
        }
    }

    /// The fixture and the script travel together: every function the fixture names must be exported.
    func testTheFixtureOnlyNamesExportedFunctions() throws {
        let exported = Set(CanonicalBusinessEngine.exportNames())
        for item in try loadCases() {
            XCTAssertTrue(exported.contains(item.function), "\(item.function) is not in the packed script")
        }
    }
}
