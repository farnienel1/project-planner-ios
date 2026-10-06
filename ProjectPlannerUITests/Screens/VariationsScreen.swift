import Foundation

struct VariationsScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.variations, timeout: 8) }

    func startCreate() { test.tap(PPID.variationsAdd) }

    func fill(heading: String, hours: String) {
        test.type(PPID.variationsHeading, heading)
        test.type(PPID.variationsDescription, "TEST- variation description")
        test.type(PPID.variationsLabourHours, hours)
        test.tap(PPID.variationsTrade)
    }

    func save() { test.tap(PPID.variationsSave) }
}
