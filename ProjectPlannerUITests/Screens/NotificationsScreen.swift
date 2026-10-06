import Foundation

struct NotificationsScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.notifications, timeout: 8) }
}
