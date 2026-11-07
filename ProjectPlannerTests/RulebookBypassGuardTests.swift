import XCTest
@testable import Project_Planner

/// Ratchet against rulebook bypasses (AGENTS.md Rule 0; project-planner-web docs/agent-rules/platform-guardrails.md
/// §1, §2). Scans every Swift file under `Project Planner/` for patterns that usually mean a screen or store decides
/// a rule itself — the phone's calendar or zone, a London literal, locale weeks, weekday numbers, role flags, email
/// equality, raw line-manager ids, a fixed clock hour — and counts them per file.
///
/// - A count above the baseline, or a file not in the baseline, fails: call the rulebook through
///   `CanonicalBusinessEngine` instead (or add the file to `allowList` with a reason a reviewer can challenge).
/// - A count below the baseline also fails until the baseline is lowered in the same change, so a fix is locked in.
/// - The deleted second calculators (`bannedSymbols`) must never come back.
///
/// Not scanned: `Canonical/` (the packed script and its engine), the bridges (`Core/Rulebook+*.swift`,
/// `Core/RulebookFoundation.swift`, `Core/*Rulebook.swift`) and `allowList`. Comment lines are skipped.
/// The failure message prints the current counts, ready to paste as the new baseline.
final class RulebookBypassGuardTests: XCTestCase {
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project Planner")
    }

    private static let patterns: [(name: String, regex: String)] = [
        ("deviceCalendar", #"Calendar\.current|TimeZone\.current|autoupdatingCurrent|Calendar = \.current|isDateInToday|isDateInWeekend"#),
        ("londonLiteral", #""Europe/London""#),
        ("weekOfYear", #"\.weekOfYear|yearForWeekOfYear"#),
        ("weekdayNumber", #"weekday\s*[=!]=\s*[17]\b|w\s*>=\s*2\s*&&\s*w\s*<=\s*6"#),
        ("roleFlags", #"role\s*[!=]=\s*\.(admin|manager|operative)|permissions\.(adminAccess|manager|operativeMode)\s*(\|\||&&)"#),
        ("emailEquality", #"email\.lowercased\(\)(\.trimmingCharacters\([^)]*\))?\s*==|emailKey\([^)]*\)\s*==|normalizedEmail\([^)]*\)\s*=="#),
        ("rawLineManagerIds", #"\.lineManagerUserIds\b|primaryLineManagerUserId|\.assignedManagerUserId\b"#),
        ("hardClockHour", #"component\(\.hour,\s*from:[^)]*\)\s*(>=|<|>|<=)\s*\d+|hour\s*>=\s*\d+\s*&&\s*hour\s*<\s*\d+"#),
    ]

    /// Second calculators deleted in the rulebook-bypass sweep. Each has a rulebook function instead.
    private static let bannedSymbols = #"\b(BookLabourCandidateSelection|LabourDayCoverage|purgeInvalidWeekendBookingsIfNeeded|workingDaysBetween|isAssignedManager|isAssignedOrBookedOnto|notifyBookingClash|hoursInsideStandardClockWindow|segmentHoursForManager|segmentHoursForOperative|holidayUserMatches|consumedDays|OperativeProfileView)\b"#

    /// Files the ratchet does not count, with the reason.
    private static let allowList: [String: String] = [
        "Views/ScheduleCalendarExport.swift": "Exports to the phone's own Calendar app, which works in the device zone by design.",
        "Core/PlaygroundDemoSeeder.swift": "Builds TEST demo data for the playground and UI tests; never a business answer.",
        "Core/MondayFirstCalendarSupport.swift": "The Monday-first month-grid helper itself (display layout only).",
        "PPDesign/PPReferencePreviews.swift": "SwiftUI preview code; not shipped behaviour.",
    ]

    private static func isScanned(_ rel: String) -> Bool {
        if rel.hasPrefix("Canonical/") { return false }
        if rel == "Core/RulebookFoundation.swift" { return false }
        let name = (rel as NSString).lastPathComponent
        if rel.hasPrefix("Core/"), !rel.dropFirst("Core/".count).contains("/") {
            if name.hasPrefix("Rulebook+") || name.hasSuffix("Rulebook.swift") { return false }
        }
        if allowList[rel] != nil { return false }
        if name.contains("Preview") { return false }
        return true
    }

    /// Per pattern, per file (relative to `Project Planner/`): the counts after the sweep. Lower a number when you
    /// remove a bypass; never raise one.
    private static let baseline: [String: [String: Int]] = [
        "deviceCalendar": [
            "Core/BookingDay.swift": 1,
            "Core/MaterialCatalogStore.swift": 1,
            "Core/NotificationService.swift": 1,
            "Core/ProjectStore.swift": 8,
            "Core/StaffEmailIdentity.swift": 2,
            "Core/TimesheetPayrollPolicy.swift": 10,
            "Core/WarningResolutionStore.swift": 1,
            "FirebaseBackend.swift": 3,
            "Models/AnnualLeavePolicy.swift": 1,
            "Models/BookingModels.swift": 1,
            "Models/ManagerScheduleInterval.swift": 1,
            "Models/MaterialsModels.swift": 1,
            "Models/OperativeBookingInterval.swift": 1,
            "Models/PeopleModels.swift": 1,
            "Models/ProjectModels.swift": 1,
            "Views/BookingHoursEditSheet.swift": 1,
            "Views/CreateProjectView.swift": 2,
            "Views/CreateSmallWorksView.swift": 2,
            "Views/DLComponents.swift": 3,
            "Views/DLModels.swift": 4,
            "Views/DLScreens.swift": 4,
            "Views/DailyOverviewView.swift": 3,
            "Views/EditMaterialView.swift": 1,
            "Views/EditProjectView.swift": 1,
            "Views/HolidayView.swift": 2,
            "Views/HomeUpNextSupport.swift": 1,
            "Views/InvoicingView.swift": 3,
            "Views/ManageUsersView.swift": 2,
            "Views/MaterialsAddWithCatalogueSheet.swift": 1,
            "Views/MaterialsSendListSheet.swift": 1,
            "Views/MaterialsView.swift": 1,
            "Views/MyScheduleView.swift": 5,
            "Views/OperativeAnnualLeaveViews.swift": 1,
            "Views/OperativeQualificationsEditorView.swift": 4,
            "Views/OrgSitesMapView.swift": 3,
            "Views/OrganisationSettingsHubView.swift": 1,
            "Views/OrganisationWorkingHoursView.swift": 2,
            "Views/ProjectDetailView.swift": 6,
            "Views/ProjectHealthSafetyView.swift": 2,
            "Views/ProjectsView.swift": 1,
            "Views/SendToWholesalerView.swift": 1,
            "Views/WarningsDetailView.swift": 3,
            "Views/WholesalersRevampViews.swift": 1,
            "Views/WorksDashboardCard.swift": 2,
        ],
        "londonLiteral": [
            "Views/OrganisationWorkingHoursView.swift": 1,
        ],
        "weekOfYear": [
            "Core/TimesheetPayrollPolicy.swift": 2,
            "Views/DLModels.swift": 2,
            "Views/MaterialsProjectListUI.swift": 1,
            "Views/MaterialsView.swift": 5,
            "Views/MyScheduleView.swift": 10,
            "Views/ProjectDetailView.swift": 3,
            "Views/ProjectHealthSafetyView.swift": 2,
        ],
        "weekdayNumber": [
            "Core/AnnualLeaveCalendarRules.swift": 2,
        ],
        "roleFlags": [
            "Core/NotificationService.swift": 7,
            "Core/QualificationsAccessPolicy.swift": 1,
            "Core/ScheduleBookingConflictSupport.swift": 8,
            "Core/ScheduleWeekGrid.swift": 1,
            "Core/TimesheetPayrollPolicy.swift": 2,
            "Core/UserStore.swift": 63,
            "Core/WarningOperativeAccess.swift": 4,
            "Core/WarningsComputation.swift": 3,
            "Core/WeeklyReportTimesheetFeed.swift": 3,
            "FirebaseBackend.swift": 13,
            "Models/AppModels.swift": 2,
            "Models/UserRoleTransitionPolicy.swift": 1,
            "Views/AddUserView.swift": 6,
            "Views/BookLabourFlowView.swift": 2,
            "Views/InvoicingView.swift": 8,
            "Views/ManageUsersView.swift": 64,
            "Views/ManagersView.swift": 1,
            "Views/OperativeAnnualLeaveViews.swift": 4,
            "Views/OrganisationSettingsHubView.swift": 2,
            "Views/Overtime/OvertimeViews.swift": 2,
            "Views/ProjectDetailView.swift": 3,
            "Views/ProjectHealthSafetyView.swift": 4,
            "Views/SettingsView.swift": 5,
            "Views/TasksDetailView.swift": 2,
            "Views/WeeklyReportView.swift": 3,
        ],
        "emailEquality": [
            "Core/NotificationService.swift": 5,
            "Core/ProjectManagerPickerSupport.swift": 3,
            "Core/ScheduleBookingConflictSupport.swift": 3,
            "Core/StaffEmailIdentity.swift": 4,
            "Core/UserStore.swift": 9,
            "Core/WeeklyReportTimesheetFeed.swift": 1,
            "Core/WorkAccess.swift": 5,
            "Models/ProjectTask.swift": 3,
            "Views/BookLabourFlowView.swift": 2,
            "Views/BookingHoursEditSheet.swift": 1,
            "Views/HolidayView.swift": 1,
            "Views/HomeView.swift": 2,
            "Views/ManageUsersView.swift": 1,
            "Views/MyScheduleView.swift": 1,
            "Views/OperativeAnnualLeaveViews.swift": 2,
            "Views/OperativesView.swift": 1,
            "Views/ProjectDetailView.swift": 2,
            "Views/ProjectsView.swift": 1,
            "Views/QualificationsManagementView.swift": 1,
            "Views/ScheduleOperativeView.swift": 1,
            "Views/SettingsView.swift": 2,
            "Views/SiteAuditView.swift": 2,
            "Views/SmallWorksView.swift": 1,
            "Views/TasksDetailView.swift": 1,
            "Views/WeeklyReportView.swift": 1,
        ],
        "rawLineManagerIds": [
            "Core/DeferredLeaveNotices.swift": 1,
            "Core/LineManagerSupport.swift": 2,
            "Core/NotificationService.swift": 1,
            "Core/UserStore.swift": 6,
            "FirebaseBackend.swift": 1,
            "Models/AppModels.swift": 3,
            "Views/HolidayView.swift": 3,
            "Views/InvoicingView.swift": 3,
            "Views/ManageUsersView.swift": 4,
        ],
        "hardClockHour": [:],
    ]

    private func swiftFiles() throws -> [(rel: String, lines: [String])] {
        let root = appRoot.standardizedFileURL
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("Cannot read \(root.path)")
            return []
        }
        var out: [(String, [String])] = []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in walker where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let rel = String(path.dropFirst(prefix.count))
            let text = try String(contentsOf: url, encoding: .utf8)
            out.append((rel, text.components(separatedBy: "\n")))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private static func count(_ regex: NSRegularExpression, in lines: [String]) -> Int {
        lines.reduce(0) { total, line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return total }
            return total + regex.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line))
        }
    }

    func testRulebookBypassCountsNeverRise() throws {
        let files = try swiftFiles()
        XCTAssertGreaterThan(files.count, 100, "the scan found the app sources")
        var current: [String: [String: Int]] = [:]
        for pattern in Self.patterns {
            let regex = try NSRegularExpression(pattern: pattern.regex)
            var perFile: [String: Int] = [:]
            for file in files where Self.isScanned(file.rel) {
                let n = Self.count(regex, in: file.lines)
                if n > 0 { perFile[file.rel] = n }
            }
            current[pattern.name] = perFile
        }

        var problems: [String] = []
        for pattern in Self.patterns {
            let now = current[pattern.name] ?? [:]
            let allowed = Self.baseline[pattern.name] ?? [:]
            for (file, n) in now.sorted(by: { $0.key < $1.key }) {
                guard let limit = allowed[file] else {
                    problems.append("\(pattern.name): \(file) has \(n) (not in the baseline) — call the rulebook instead")
                    continue
                }
                if n > limit {
                    problems.append("\(pattern.name): \(file) rose from \(limit) to \(n) — call the rulebook instead")
                } else if n < limit {
                    problems.append("\(pattern.name): \(file) dropped from \(limit) to \(n) — lower the baseline")
                }
            }
            for (file, limit) in allowed where now[file] == nil {
                problems.append("\(pattern.name): \(file) dropped from \(limit) to 0 — remove it from the baseline")
            }
        }
        if !problems.isEmpty {
            XCTFail(problems.joined(separator: "\n") + "\n\nCurrent counts:\n" + Self.render(current))
        }
    }

    func testDeletedSecondCalculatorsStayDeleted() throws {
        let regex = try NSRegularExpression(pattern: Self.bannedSymbols)
        var hits: [String] = []
        for file in try swiftFiles() where !file.rel.hasPrefix("Canonical/") {
            let n = Self.count(regex, in: file.lines)
            if n > 0 { hits.append("\(file.rel): \(n)") }
        }
        XCTAssertEqual(hits, [], "a deleted second calculator is back; call the rulebook function instead")
    }

    func testEveryAllowListedFileExists() {
        for path in Self.allowList.keys.sorted() {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: appRoot.appendingPathComponent(path).path),
                "\(path) is allow-listed but missing; drop it from allowList"
            )
        }
    }

    private static func render(_ counts: [String: [String: Int]]) -> String {
        patterns.map { pattern in
            let rows = (counts[pattern.name] ?? [:]).sorted { $0.key < $1.key }
                .map { "            \"\($0.key)\": \($0.value)," }
            return rows.isEmpty
                ? "        \"\(pattern.name)\": [:],"
                : "        \"\(pattern.name)\": [\n" + rows.joined(separator: "\n") + "\n        ],"
        }.joined(separator: "\n")
    }
}
