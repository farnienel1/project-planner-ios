import Foundation

/// User Timesheets lists (Awaiting, Signed off, Exported) — display only (owner 24 Nov, web #451): the short dates,
/// the "Versions · N" disclosure and the line-manager labels. Every date is read in the organisation's time zone
/// (`OrganizationRulebookContext.timeZone`, never the device's); nothing here decides pay, hours or who sees what.
enum TimesheetListDisplay {
    private static func parts(_ date: Date, _ timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static func month(_ components: DateComponents) -> String {
        let index = (components.month ?? 1) - 1
        return months.indices.contains(index) ? months[index] : ""
    }

    /// "24 Nov, 20:07"; the year only when it is not the current year in the organisation zone ("24 Nov 2025, 20:07").
    /// The same text as web `formatExportedStamp`.
    static func exportedStamp(_ date: Date, timeZone: TimeZone, now: Date = Date()) -> String {
        let at = parts(date, timeZone)
        let today = parts(now, timeZone)
        let day = at.year == today.year
            ? "\(at.day ?? 0) \(month(at))"
            : "\(at.day ?? 0) \(month(at)) \(at.year ?? 0)"
        return String(format: "%@, %02d:%02d", day, at.hour ?? 0, at.minute ?? 0)
    }

    /// "16–30 Nov 2026"; across months "26 Oct – 25 Nov 2026"; across years "29 Dec 2025 – 4 Jan 2026"
    /// (web `formatCompactPayRun`).
    static func compactPayRun(start: Date, end: Date, timeZone: TimeZone) -> String {
        let from = parts(start, timeZone)
        let to = parts(end, timeZone)
        if from.year == to.year, from.month == to.month {
            return "\(from.day ?? 0)–\(to.day ?? 0) \(month(to)) \(to.year ?? 0)"
        }
        if from.year == to.year {
            return "\(from.day ?? 0) \(month(from)) – \(to.day ?? 0) \(month(to)) \(to.year ?? 0)"
        }
        return "\(from.day ?? 0) \(month(from)) \(from.year ?? 0) – \(to.day ?? 0) \(month(to)) \(to.year ?? 0)"
    }

    /// Opens or closes one row's versions list (collapsed by default, owner 24 Nov).
    static func toggled(_ open: Set<String>, rowId: String) -> Set<String> {
        var next = open
        if next.contains(rowId) { next.remove(rowId) } else { next.insert(rowId) }
        return next
    }
}

/// Which Exported rows have their versions list open, kept for this app session only (no storage).
@MainActor
enum ExportedVersionsDisclosure {
    static var openRowIds: Set<String> = []
}

/// The "Line manager" label on the User Timesheets lists: the rulebook's `lineManagerSummary` (§11) through
/// `CanonicalBusinessEngine`, over every users document of the organisation (`UserStore.unfoldedOrganizationUsers`),
/// so a line manager stored under a same-email second document, a former invite id or another letter case is named.
/// Before 24 Nov `InvoicingView.lineManagerName(for:)` matched only `assignedManagerUserId`, exactly, against the
/// email-folded roster and showed "Unknown" / "Unassigned".
///
/// Performance (review of web #451): the roster rows are built once per roster and each label is cached by the
/// person's stored line-manager fields (all `lineManagerSummary` reads from the person), so a list calls the script
/// once per distinct line manager, not once per row per render.
@MainActor
final class LineManagerLabelCache {
    static let shared = LineManagerLabelCache()

    private var rosterSignature = ""
    private var rosterRows: [[String: Any]] = []
    private var labels: [String: String] = [:]

    private static func signature(_ users: [AppUser]) -> String {
        users.map { user in
            [
                user.id, user.email, user.firstName, user.surname, user.documentName,
                user.documentDisplayName, user.isActive ? "1" : "0", String(describing: user.passwordSet),
                user.formerUserIds.joined(separator: ","), user.sameEmailUserIds.joined(separator: ","),
            ].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
    }

    private static func key(_ person: AppUser) -> String {
        let ids = person.assignedManagerUserIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let single = person.assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(person.hasNoLineManager ? 1 : 0)|\(ids.joined(separator: ","))|\(single)"
    }

    func label(for person: AppUser, roster users: [AppUser]) -> String {
        let signature = Self.signature(users)
        if signature != rosterSignature {
            rosterSignature = signature
            rosterRows = LineManagerRulebook.roster(users)
            labels = [:]
        }
        let key = Self.key(person)
        if let hit = labels[key] { return hit }
        let label = CanonicalBusinessEngine.lineManagerSummaryLabel(person: LineManagerRulebook.row(person), roster: rosterRows)
            ?? (person.hasNoLineManager ? "No line manager" : "Not set")
        labels[key] = label
        return label
    }
}
