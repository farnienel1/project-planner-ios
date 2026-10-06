import Foundation

struct SiteAuditScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.siteAudit, timeout: 8) }

    func startAndSaveNote() {
        test.tap(PPID.siteAuditStart)
        test.type(PPID.siteAuditNotes, "TEST- audit note")
        test.tap(PPID.siteAuditSave)
    }
}
