#if DEBUG
import Foundation

/// Test-only launch hook. It runs only when the process was started with `-uiTesting`.
/// Release builds omit this file's body. It does not change production launches.
enum UITestingMode {
    static var isEnabled: Bool {
        CommandLine.arguments.contains("-uiTesting")
    }

    static var seedEmpty: Bool {
        CommandLine.arguments.contains("-seedEmpty")
    }

    static var seedDemoData: Bool {
        CommandLine.arguments.contains("-seedDemoData")
    }

    static var shouldSkipNetworkBootstrap: Bool {
        isEnabled && autoLoginRole != nil
    }

    static var autoLoginRole: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "-autoLoginRole"),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static var prefersDark: Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "-AppleInterfaceStyle"),
              index + 1 < CommandLine.arguments.count else { return false }
        return CommandLine.arguments[index + 1].caseInsensitiveCompare("Dark") == .orderedSame
    }

    @MainActor
    static func apply(
        backend: FirebaseBackend,
        userStore: UserStore,
        projectStore: ProjectStore,
        operativeStore: OperativeStore,
        appSettings: AppSettingsStore
    ) {
        guard isEnabled, let roleName = autoLoginRole else { return }

        let theme: ThemePreference = prefersDark ? .dark : .light
        appSettings.settings.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: "appAppearanceMode")

        let orgId = "uitest-org"
        let org = Organization(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID(), firestoreDocumentId: orgId, name: seedEmpty ? "TEST-Empty Org" : "TEST-Org")
        backend.currentOrganization = org
        backend.isAuthenticated = true

        let signedIn = user(roleName: roleName, orgId: orgId)
        userStore.currentUser = signedIn
        if seedEmpty {
            userStore.organizationUsers = [signedIn]
            projectStore.projects = []
            projectStore.clients = []
            operativeStore.operatives = []
            operativeStore.managers = []
            return
        }

        let managerUser = user(roleName: "manager", orgId: orgId)
        let operativeUser = user(roleName: "operative", orgId: orgId)
        userStore.organizationUsers = [signedIn, managerUser, operativeUser]

        let client = Client(name: "TEST-Client Alpha", email: "client@example.test")
        projectStore.clients = [client]
        let managerId = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF") ?? UUID()
        let project = Project(
            jobNumber: "TEST-P100",
            siteName: "TEST-Kitchen refit",
            addressLine1: "1 Test Street",
            townCity: "London",
            postcode: "SW1A 1AA",
            client: client,
            startDate: Date(),
            endDate: Date().addingTimeInterval(60 * 60 * 24 * 14),
            jobType: .catA,
            manager: .na,
            managerId: managerId,
            managerIds: [managerId],
            isLive: true,
            description: "TEST- seeded project"
        )
        let small = Project(
            jobNumber: "TEST-SW100",
            siteName: "TEST-Snagging",
            addressLine1: "2 Test Street",
            townCity: "London",
            postcode: "SW1A 2AA",
            client: client,
            startDate: Date(),
            endDate: Date().addingTimeInterval(60 * 60 * 24 * 3),
            jobType: .smallWorks,
            manager: .na,
            managerId: managerId,
            isLive: true,
            description: "TEST- seeded small works"
        )
        projectStore.projects = [project, small]
        operativeStore.operatives = [
            Operative(
                firstName: "TEST",
                lastName: "Operative",
                email: "operative@example.test",
                startDate: Date()
            )
        ]
        operativeStore.managers = [
            Manager(
                id: managerId,
                firstName: "TEST",
                lastName: "Manager",
                email: "manager@example.test",
                mobileNumber: "07000000000"
            )
        ]
    }

    private static func user(roleName: String, orgId: String) -> AppUser {
        switch roleName {
        case "manager":
            return AppUser(
                id: "uitest-manager",
                email: "manager@example.test",
                organizationId: orgId,
                role: .manager,
                firstName: "TEST",
                surname: "Manager",
                passwordSet: true,
                permissions: UserPermissions(
                    manager: true,
                    operatives: true,
                    qualifications: true,
                    materials: true,
                    projects: true,
                    smallWorks: true,
                    weeklyReports: true,
                    dailyOverview: true,
                    subContractors: true,
                    siteAudit: true,
                    wholesalersOrderHistory: true
                ),
                policyAccepted: true,
                employmentType: .selfEmployed,
                timesheetsEnabled: true
            )
        case "operative":
            return AppUser(
                id: "uitest-operative",
                email: "operative@example.test",
                organizationId: orgId,
                role: .operative,
                firstName: "TEST",
                surname: "Operative",
                passwordSet: true,
                permissions: UserPermissions(
                    materials: true,
                    operativeMode: true,
                    siteAudit: true
                ),
                policyAccepted: true,
                employmentType: .selfEmployed,
                timesheetsEnabled: true
            )
        default:
            return AppUser(
                id: "uitest-admin",
                email: "admin@example.test",
                organizationId: orgId,
                role: .admin,
                firstName: "TEST",
                surname: "Admin",
                passwordSet: true,
                permissions: UserPermissions(
                    adminAccess: true,
                    manager: true,
                    operatives: true,
                    qualifications: true,
                    materials: true,
                    projects: true,
                    smallWorks: true,
                    weeklyReports: true,
                    dailyOverview: true,
                    subContractors: true,
                    siteAudit: true,
                    wholesalersOrderHistory: true
                ),
                isSuperAdmin: true,
                policyAccepted: true,
                employmentType: .selfEmployed,
                timesheetsEnabled: true
            )
        }
    }
}
#endif
