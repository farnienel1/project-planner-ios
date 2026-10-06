import Foundation

struct LibraryScreen {
    let test: PPUITestCase

    func assertClients() { test.assertExists(PPID.libraryClients, timeout: 8) }

    func addClient(name: String) {
        test.tap(PPID.libraryClientsAdd)
        test.type(PPID.libraryClientName, name)
        test.tap(PPID.libraryClientsSave)
    }

    func searchClients(_ text: String) {
        test.type(PPID.libraryClientsSearch, text)
    }
}
