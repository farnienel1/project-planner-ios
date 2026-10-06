import Foundation

struct SettingsScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.settings, timeout: 8) }

    func openOrganisationHub() {
        test.scrollTo(PPID.settingsOrganisationHub)
        test.tap(PPID.settingsOrganisationHub)
    }

    func openWorkingHours() { test.tap(PPID.settingsWorkingHours) }
    func openAnnualLeave() { test.tap(PPID.settingsAnnualLeave) }
    func openScheduleOptions() { test.tap(PPID.settingsScheduleOptions) }
    func openWarnings() { test.tap(PPID.settingsWarnings) }
    func openPaymentRuns() { test.tap(PPID.settingsPaymentRuns) }
}
