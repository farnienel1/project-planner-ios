import Foundation

struct ProfileScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.profile, timeout: 8) }

    func assertNameShown() { test.assertExists(PPID.profileName) }
}
