import Foundation

struct PeopleScreen {
    let test: PPUITestCase

    func assertAddUser() { test.assertExists(PPID.peopleAddUser, timeout: 8) }

    func saveEmpty() { test.tap(PPID.peopleSave) }

    func assertValidation() { test.assertExists(PPID.peopleValidation) }

    func assertOperatives() { test.assertExists(PPID.peopleOperatives, timeout: 8) }

    func assertSubcontractors() { test.assertExists(PPID.peopleSubcontractors, timeout: 8) }
}
