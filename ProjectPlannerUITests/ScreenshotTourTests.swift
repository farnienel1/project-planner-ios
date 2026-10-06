import XCTest

/// Walks the screens each role can open and keeps a screenshot of every state it reaches.
/// Navigation tries the accessibility identifier first, then the visible label.
final class ScreenshotTourTests: PPUITestCase {
    private var missed: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = true
        missed = []
    }

    func test_tour_01_admin_light() {
        runTour(role: "admin", appearance: .light, seed: .demo, includeLoggedOut: true)
    }

    func test_tour_02_admin_dark() {
        runTour(role: "admin", appearance: .dark, seed: .demo, includeLoggedOut: false)
    }

    func test_tour_03_admin_large() {
        runTour(role: "admin", appearance: .large, seed: .demo, includeLoggedOut: false)
    }

    func test_tour_04_manager_light() {
        runTour(role: "manager", appearance: .light, seed: .demo, includeLoggedOut: false)
    }

    func test_tour_05_manager_dark() {
        runTour(role: "manager", appearance: .dark, seed: .demo, includeLoggedOut: false)
    }

    func test_tour_06_manager_large() {
        runTour(role: "manager", appearance: .large, seed: .demo, includeLoggedOut: false)
    }

    func test_tour_07_operative_light() {
        runTour(role: "operative", appearance: .light, seed: .demo, includeLoggedOut: false)
    }

    func test_tour_08_operative_dark() {
        runTour(role: "operative", appearance: .dark, seed: .demo, includeLoggedOut: false)
    }

    func test_tour_09_operative_large() {
        runTour(role: "operative", appearance: .large, seed: .demo, includeLoggedOut: false)
    }

    func test_tour_10_admin_light_empty() {
        runTour(role: "admin", appearance: .light, seed: .empty, includeLoggedOut: false)
    }

    private func runTour(role: String, appearance: TourAppearance, seed: TourSeed, includeLoggedOut: Bool) {
        missed = []
        if includeLoggedOut {
            launch(role: nil, resetState: false, extraArguments: appearance.arguments)
            capture(role: "logged-out", appearance: appearance, module: "auth", screen: "login", state: "empty")
            tapLabel("Sign In")
            capture(role: "logged-out", appearance: appearance, module: "auth", screen: "login", state: "validation-error")
            if tapLabel("Forgot password?") {
                capture(role: "logged-out", appearance: appearance, module: "auth", screen: "reset-password", state: "empty")
            } else {
                missed.append("auth.reset-password")
            }
        }

        let seedFlag = seed == .demo ? "-seedDemoData" : "-seedEmpty"
        launch(role: role, resetState: false, extraArguments: appearance.arguments + [seedFlag])
        let homeReady = element(PPID.home).waitForExistence(timeout: 8)
            || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Hi,")).firstMatch.waitForExistence(timeout: 6)
        guard homeReady else {
            capture(role: role, appearance: appearance, module: "auth", screen: "login", state: "blocked")
            missed.append("home (auto-login did not show Home)")
            finishMissed(role: role, appearance: appearance)
            return
        }

        captureScroll(role: role, appearance: appearance, module: "home", screen: "home", state: seed == .empty ? "empty" : "populated")
        visit(id: PPID.homeNotifications, label: "Notifications", role: role, appearance: appearance, module: "home", screen: "notifications", state: "list")
        visit(id: PPID.homeCustomise, label: "Customise", role: role, appearance: appearance, module: "home", screen: "customise", state: "jiggle", leaveOpen: true)
        _ = tap(id: PPID.homeCustomiseDone, label: "Done")
        if role == "admin" {
            visit(id: PPID.homeWarnings, label: "Warnings", role: role, appearance: appearance, module: "warnings", screen: "list", state: seed == .empty ? "empty" : "populated")
            visit(id: PPID.homeOverviewSettings, label: "Customize dashboard metrics", role: role, appearance: appearance, module: "home", screen: "overview-settings", state: "sheet")
        }
        visit(id: "home.tasks", label: "Tasks", role: role, appearance: appearance, module: "tasks", screen: "list", state: seed == .empty ? "empty" : "populated")

        let quick = RoleSurfaces.homeQuickActions(role: role)
        for button in quick.required + quick.optional {
            let label = Self.quickLabel(for: button.id)
            visit(id: button.id, label: label, role: role, appearance: appearance, module: Self.module(for: button), screen: "quick-action", state: "opened")
        }

        if openMenu(id: PPID.homeMainMenu, label: "Main Menu", sheet: PPID.mainMenu) {
            capture(role: role, appearance: appearance, module: "navigation", screen: "main-menu", state: "sheet")
            let menu = RoleSurfaces.menuRows(role: role)
            for button in menu.required + menu.optional {
                if case .editTabBar = button.kind { continue }
                if isSignOut(button) { continue }
                let label = Self.rowLabel(for: button.id)
                if !tap(id: button.id, label: label) {
                    missed.append("mainMenu.\(label)")
                    continue
                }
                captureScroll(role: role, appearance: appearance, module: Self.module(for: button), screen: label, state: "opened")
                captureFormStates(role: role, appearance: appearance, module: Self.module(for: button), screen: label)
                softBack()
                _ = openMenu(id: PPID.homeMainMenu, label: "Main Menu", sheet: PPID.mainMenu)
            }
            if tap(id: PPID.mainMenuRow("edit_tab_bar"), label: "Edit main menu bar") {
                capture(role: role, appearance: appearance, module: "navigation", screen: "tab-bar", state: "jiggle")
                _ = tap(id: PPID.homeEditTabBarDone, label: "Done")
            }
            _ = tap(id: PPID.mainMenuDone, label: "Done")
        } else {
            missed.append("mainMenu")
        }

        if openMenu(id: PPID.tabMore, label: "More", sheet: PPID.more) {
            capture(role: role, appearance: appearance, module: "navigation", screen: "more", state: "sheet")
            _ = tap(id: PPID.moreClose, label: "Close")
        } else {
            missed.append("more")
        }

        if seed == .demo && role != "operative" {
            openProjectDetail(role: role, appearance: appearance)
        }

        finishMissed(role: role, appearance: appearance)
    }

    private func openProjectDetail(role: String, appearance: TourAppearance) {
        if !tap(id: PPID.homeQuickAction("staff-projects"), label: "Projects") {
            missed.append("projects.list")
            return
        }
        captureScroll(role: role, appearance: appearance, module: "projects", screen: "list", state: "populated")
        if tap(id: "projects.row.TEST", label: "TEST-Kitchen refit") {
            captureScroll(role: role, appearance: appearance, module: "projects", screen: "detail", state: "populated")
            if tap(id: PPID.projectDetailVariations, label: "Variations") {
                capture(role: role, appearance: appearance, module: "variations", screen: "list", state: "opened")
                softBack()
            }
            softBack()
        } else {
            missed.append("projects.detail")
        }
        if tap(id: PPID.projectsAdd, label: "Add") || tapLabel("plus") {
            capture(role: role, appearance: appearance, module: "projects", screen: "form", state: "empty")
            if tap(id: PPID.projectsSave, label: "Save") {
                capture(role: role, appearance: appearance, module: "projects", screen: "form", state: "validation-error")
            }
            softBack()
        }
        softBack()
    }

    private func captureFormStates(role: String, appearance: TourAppearance, module: String, screen: String) {
        let save = app.buttons["Save"]
        guard save.waitForExistence(timeout: 1) else { return }
        capture(role: role, appearance: appearance, module: module, screen: "form", state: "empty")
        save.tap()
        capture(role: role, appearance: appearance, module: module, screen: "form", state: "validation-error")
    }

    private func visit(id: String, label: String, role: String, appearance: TourAppearance, module: String, screen: String, state: String, leaveOpen: Bool = false) {
        guard tap(id: id, label: label) else {
            missed.append("\(module).\(screen)")
            return
        }
        captureScroll(role: role, appearance: appearance, module: module, screen: screen, state: state)
        if !leaveOpen { softBack() }
    }

    @discardableResult
    private func tap(id: String, label: String) -> Bool {
        let identified = element(id)
        if identified.waitForExistence(timeout: 2), identified.isHittable {
            identified.tap()
            return true
        }
        return tapLabel(label)
    }

    @discardableResult
    private func tapLabel(_ label: String) -> Bool {
        let predicate = NSPredicate(format: "label == %@ OR label CONTAINS[c] %@", label, label)
        let button = app.buttons.matching(predicate).firstMatch
        if button.waitForExistence(timeout: 1.5), button.isHittable {
            button.tap()
            return true
        }
        let text = app.staticTexts.matching(predicate).firstMatch
        if text.waitForExistence(timeout: 1), text.isHittable {
            text.tap()
            return true
        }
        return false
    }

    @discardableResult
    private func openMenu(id: String, label: String, sheet: String) -> Bool {
        guard tap(id: id, label: label) else { return false }
        return element(sheet).waitForExistence(timeout: 2) || app.staticTexts[label].waitForExistence(timeout: 2)
    }

    private func softBack() {
        for label in ["Done", "Close", "Back", "Cancel"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                return
            }
        }
        let nav = app.navigationBars.buttons.firstMatch
        if nav.exists, nav.isHittable {
            nav.tap()
            return
        }
        _ = tap(id: PPID.tabHome, label: "Home")
    }

    private func captureScroll(role: String, appearance: TourAppearance, module: String, screen: String, state: String) {
        capture(role: role, appearance: appearance, module: module, screen: screen, state: "\(state)-top")
        let scroll = app.scrollViews.firstMatch
        if scroll.exists {
            scroll.swipeUp()
            capture(role: role, appearance: appearance, module: module, screen: screen, state: "\(state)-bottom")
        }
    }

    private func capture(role: String, appearance: TourAppearance, module: String, screen: String, state: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(role)__\(appearance.rawValue)__\(module)__\(screen)__\(state)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func finishMissed(role: String, appearance: TourAppearance) {
        let body = missed.isEmpty ? "none" : missed.joined(separator: "\n")
        let note = XCTAttachment(string: body)
        note.name = "\(role)__\(appearance.rawValue)__meta__missed__list"
        note.lifetime = .keepAlways
        add(note)
    }

    private func isSignOut(_ button: PPButton) -> Bool {
        button.id.contains("sign_out")
    }

    private static func quickLabel(for id: String) -> String {
        if id.contains("projects") { return "Projects" }
        if id.contains("small") { return "Small" }
        if id.contains("leave") { return "Annual" }
        if id.contains("schedule") { return "Schedule" }
        if id.contains("audit") { return "audit" }
        if id.contains("settings") { return "Settings" }
        if id.contains("weekly") { return "Weekly" }
        if id.contains("daily") { return "Daily" }
        if id.contains("tasks") { return "Tasks" }
        if id.contains("managers") { return "Managers" }
        if id.contains("operatives") { return "Operatives" }
        if id.contains("subs") { return "contractors" }
        if id.contains("map") { return "map" }
        if id.contains("invoicing") { return "Timesheets" }
        return id
    }

    private static func rowLabel(for id: String) -> String {
        if id.contains("clients") { return "Clients" }
        if id.contains("projects") { return "Projects" }
        if id.contains("small") { return "Small works" }
        if id.contains("managers") { return "Managers" }
        if id.contains("holiday") { return "Annual Leave" }
        if id.contains("site_map") { return "Site map" }
        if id.contains("site_audit") { return "Site audit" }
        if id.contains("qualifications") { return "Qualifications" }
        if id.contains("my_qualifications") { return "My qualifications" }
        if id.contains("job_types") { return "Job types" }
        if id.contains("material") { return "Material catalogue" }
        if id.contains("subcontractors") { return "Sub contractors" }
        if id.contains("add_user") { return "Add user" }
        if id.contains("manage_users") { return "Manage" }
        if id.contains("settings") { return "Settings" }
        if id.contains("help") { return "Help" }
        if id.contains("operatives") { return "Operatives" }
        if id.contains("wholesalers") { return "Wholesalers" }
        if id.contains("invoicing") { return "Timesheets" }
        return id
    }

    private static func module(for button: PPButton) -> String {
        let id = button.id
        if id.contains("project") { return "projects" }
        if id.contains("small") { return "small-works" }
        if id.contains("leave") || id.contains("holiday") { return "leave" }
        if id.contains("schedule") || id.contains("weekly") || id.contains("daily") { return "schedule" }
        if id.contains("audit") || id.contains("map") { return "site-audit" }
        if id.contains("setting") { return "settings" }
        if id.contains("task") { return "tasks" }
        if id.contains("manager") || id.contains("operative") || id.contains("user") || id.contains("sub") { return "people" }
        if id.contains("client") || id.contains("job") || id.contains("qualif") || id.contains("material") || id.contains("whole") { return "library" }
        if id.contains("invoice") || id.contains("timesheet") { return "timesheets" }
        if id.contains("help") { return "settings" }
        return "navigation"
    }
}

private enum TourAppearance: String {
    case light
    case dark
    case large

    var arguments: [String] {
        switch self {
        case .light:
            return []
        case .dark:
            return ["-AppleInterfaceStyle", "Dark"]
        case .large:
            return ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        }
    }
}

private enum TourSeed {
    case demo
    case empty
}
