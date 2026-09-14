//
//  DLModels.swift
//  Project Planner — Deadlines
//
//  DROP-IN FILE. Models + derived logic for the Deadlines tab.
//  Depends on HSTheme.swift only (for Color tokens). No services, no persistence.
//
//  The important idea in this file is that almost nothing about a deadline's
//  appearance is stored. Urgency, risk and slippage are all COMPUTED from the
//  dates and the progress figure, so a deadline can never sit in the list
//  claiming to be "on track" because somebody forgot to update a status field.
//

import SwiftUI

// MARK: - Status
//
// Status is what a human set. Urgency (below) is what the calendar says.
// Keep them separate: a job can be "In progress" and "Overdue" at once.

enum DLStatus: String, CaseIterable, Identifiable, Hashable, Codable {
    case notStarted, inProgress, blocked, complete

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .blocked:    return "Blocked"
        case .complete:   return "Complete"
        }
    }

    var icon: String {
        switch self {
        case .notStarted: return "circle.dashed"
        case .inProgress: return "circle.lefthalf.filled"
        case .blocked:    return "exclamationmark.octagon.fill"
        case .complete:   return "checkmark.circle.fill"
        }
    }
}

// MARK: - Urgency
//
// Derived from the due date every time it is read. Never stored.

enum DLUrgency: Hashable {
    case complete
    case blocked
    case overdue(days: Int)
    case today
    case tomorrow
    case soon(days: Int)      // 2–3 days
    case thisWeek(days: Int)  // 4–7 days
    case later(days: Int)

    /// The one-line phrase shown on the card, e.g. "3 days overdue", "Due in 4 days".
    var phrase: String {
        switch self {
        case .complete:          return "Complete"
        case .blocked:           return "Blocked"
        case .overdue(let d):    return d == 1 ? "1 day overdue" : "\(d) days overdue"
        case .today:             return "Due today"
        case .tomorrow:          return "Due tomorrow"
        case .soon(let d):       return "Due in \(d) days"
        case .thisWeek(let d):   return "Due in \(d) days"
        case .later(let d):      return d > 60 ? "Due in \(d / 7) weeks" : "Due in \(d) days"
        }
    }

    /// Short form for the countdown pill on the right of a card.
    var pillText: String {
        switch self {
        case .complete:          return "Done"
        case .blocked:           return "Held"
        case .overdue(let d):    return "+\(d)d"
        case .today:             return "Today"
        case .tomorrow:          return "1d"
        case .soon(let d),
             .thisWeek(let d):   return "\(d)d"
        case .later(let d):      return d > 60 ? "\(d / 7)w" : "\(d)d"
        }
    }

    var accent: Color {
        switch self {
        case .complete:              return HS.green
        case .blocked:               return HS.violet
        case .overdue:               return HS.red
        case .today, .tomorrow:      return HS.amber
        case .soon:                  return HS.amber
        case .thisWeek:              return HS.blue
        case .later:                 return HS.slate
        }
    }

    var tint: Color {
        switch self {
        case .complete:              return HS.greenBg
        case .blocked:               return HS.violetBg
        case .overdue:               return HS.redBg
        case .today, .tomorrow:      return HS.amberBg
        case .soon:                  return HS.amberBg
        case .thisWeek:              return HS.blueBg
        case .later:                 return HS.neutralBg
        }
    }

    /// Sort weight so the list always leads with what is on fire.
    var rank: Int {
        switch self {
        case .overdue:  return 0
        case .today:    return 1
        case .tomorrow: return 2
        case .soon:     return 3
        case .thisWeek: return 4
        case .blocked:  return 5
        case .later:    return 6
        case .complete: return 7
        }
    }

    var isOverdue: Bool { if case .overdue = self { return true }; return false }
}

// MARK: - Audit trail
//
// Every change to a date is recorded with a reason. On site the question that
// matters six months later is never "when is it due" but "when did it move,
// who moved it and why". The UI surfaces this on the detail sheet.

struct DLChange: Identifiable, Hashable {
    enum Kind: Hashable {
        case created(due: Date)
        case rescheduled(from: Date, to: Date, reason: String)
        case progress(to: Int)
        case status(to: DLStatus)
        case note(String)
        case completed(on: Date)
        case assigned(to: String)
        case fileAttached(name: String)
        case siteAuditAttached(name: String)
    }

    var id: UUID = UUID()
    var at: Date
    var author: String
    var kind: Kind

    var icon: String {
        switch kind {
        case .created:     return "plus.circle.fill"
        case .rescheduled: return "calendar.badge.exclamationmark"
        case .progress:    return "chart.bar.fill"
        case .status:      return "arrow.triangle.2.circlepath"
        case .note:        return "text.bubble.fill"
        case .completed:   return "checkmark.seal.fill"
        case .assigned:    return "person.fill.badge.plus"
        case .fileAttached, .siteAuditAttached: return "paperclip"
        }
    }

    var tint: Color {
        switch kind {
        case .rescheduled: return HS.amber
        case .completed:   return HS.green
        case .status:      return HS.violet
        case .progress:    return HS.blue
        default:           return HS.slate
        }
    }

    var line: String {
        switch kind {
        case .created(let due):
            return "Created, due \(DLFormat.day(due))"
        case .rescheduled(let from, let to, let reason):
            let dir = to > from ? "Pushed" : "Pulled forward"
            return "\(dir) \(DLFormat.day(from)) → \(DLFormat.day(to)) · \(reason)"
        case .progress(let pct):
            return "Progress updated to \(pct)%"
        case .status(let s):
            return "Marked \(s.label.lowercased())"
        case .note(let text):
            return text
        case .completed(let on):
            return "Completed on \(DLFormat.day(on))"
        case .assigned(let who):
            return "Assigned to \(who)"
        case .fileAttached(let name):
            return "Attached file · \(name)"
        case .siteAuditAttached(let name):
            return "Attached site audit · \(name)"
        }
    }
}

/// A person who can be assigned to a deadline. `id` is the app user id.
struct DLPerson: Identifiable, Hashable {
    let id: String
    var name: String
    var subtitle: String
    var isLive: Bool
}

/// Lightweight site-audit row used by the deadline editor (keeps Deadlines files off Site Audit types).
struct DLSiteAuditRef: Identifiable, Hashable {
    let id: UUID
    var title: String
    var typeLabel: String
    var date: Date
    var itemCount: Int
    var authorName: String
    var jobLine: String
}

// MARK: - The deadline

struct DLDeadline: Identifiable, Hashable {
    var id: UUID = UUID()

    // What and where
    var title: String                 // "3rd Floor WC 1st Fix"
    var location: String?             // "3rd Floor"  — the spine of the Floor grouping
    var trade: String?                // "Plumbing & Gas" — matches the H&S Trade enum labels
    var detail: String?               // free text shown on the detail sheet

    // When
    var start: Date?                  // optional; enables the pacing bar
    var due: Date
    var completedAt: Date?

    // Who
    var assignees: [String] = []      // display names for cards / history
    var assigneeUserIds: [String] = [] // app user ids — visibility, notify, picker
    var company: String?              // "Hydro M&E Ltd"

    // How it is going
    var status: DLStatus = .notStarted
    var progress: Double = 0          // 0...1, manually set
    var isCritical: Bool = false      // on the critical path — slipping this slips the job
    var dependsOn: [UUID] = []        // predecessors
    var blockedReason: String?

    // Bookkeeping
    var reminderDaysBefore: Int? = 2
    var originalDue: Date?            // set the first time it is rescheduled
    var history: [DLChange] = []

    // The deadline belongs to a Project or a Small Work; the tab is shared.
    var contextKind: String = "Project"
    var projectId: UUID? = nil
    var createdByUserId: String = ""

    // One upload (snag list / drawing / PDF) and one site audit.
    var fileURL: String? = nil
    var fileName: String? = nil
    var siteAuditId: UUID? = nil
    var siteAuditTitle: String? = nil
}

// MARK: - Derived logic
//
// All of it pure, all of it testable, none of it stored.

extension DLDeadline {

    private var cal: Calendar { Calendar.current }

    /// Whole days from `now` to `due`. Negative means overdue.
    func daysRemaining(now: Date = Date()) -> Int {
        let a = cal.startOfDay(for: now)
        let b = cal.startOfDay(for: due)
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }

    func urgency(now: Date = Date()) -> DLUrgency {
        if status == .complete { return .complete }
        let d = daysRemaining(now: now)
        if d < 0 { return .overdue(days: -d) }
        if status == .blocked { return .blocked }
        switch d {
        case 0:      return .today
        case 1:      return .tomorrow
        case 2...3:  return .soon(days: d)
        case 4...7:  return .thisWeek(days: d)
        default:     return .later(days: d)
        }
    }

    /// Where progress SHOULD be today if the work were running evenly between
    /// start and due. This is what makes the pacing bar work: we draw the
    /// actual fill, then a marker at this value. A gap you can see is a gap
    /// you act on.
    func expectedProgress(now: Date = Date()) -> Double? {
        guard let start, due > start else { return nil }
        let total = due.timeIntervalSince(start)
        let done  = now.timeIntervalSince(start)
        return min(max(done / total, 0), 1)
    }

    /// Behind pace by more than 15 points, with the finish line in sight.
    /// Deliberately conservative — an at-risk badge that cries wolf gets ignored.
    func isAtRisk(now: Date = Date()) -> Bool {
        guard status != .complete else { return false }
        if status == .blocked && daysRemaining(now: now) <= 7 { return true }
        guard let expected = expectedProgress(now: now) else { return false }
        return expected - progress > 0.15 && daysRemaining(now: now) >= 0
    }

    /// How far behind pace, in points, for the "X% behind pace" line.
    func pacingGap(now: Date = Date()) -> Int? {
        guard let expected = expectedProgress(now: now), expected > progress else { return nil }
        return Int(((expected - progress) * 100).rounded())
    }

    /// Total days this deadline has moved since it was first set.
    var slippageDays: Int {
        guard let originalDue else { return 0 }
        return Calendar.current.dateComponents([.day], from: originalDue, to: due).day ?? 0
    }

    var timesRescheduled: Int {
        history.filter { if case .rescheduled = $0.kind { return true }; return false }.count
    }

    var progressPercent: Int { Int((progress * 100).rounded()) }

    var initialsForAssignees: [String] {
        assignees.map { name in
            name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        }
    }

    /// One-line summary used by the widget/notification copy and the share sheet.
    func summaryLine(now: Date = Date()) -> String {
        let where_ = location.map { "\($0) · " } ?? ""
        return "\(where_)\(title) — \(urgency(now: now).phrase)"
    }
}

// MARK: - Formatting

enum DLFormat {
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()
    private static let fullFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM yyyy"; return f
    }()
    private static let weekdayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEEE"; return f   // single letter
    }()
    private static let dayNumFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"; return f
    }()

    static func day(_ d: Date)     -> String { dayFmt.string(from: d) }
    static func full(_ d: Date)    -> String { fullFmt.string(from: d) }
    static func weekday(_ d: Date) -> String { weekdayFmt.string(from: d) }
    static func dayNum(_ d: Date)  -> String { dayNumFmt.string(from: d) }
    static func stamp(_ d: Date)   -> String { timeFmt.string(from: d) }

    static func weekCommencing(_ d: Date) -> String {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)) ?? d
        return "W/C \(day(start))"
    }
}

// MARK: - Grouping
//
// Site managers do not think in one list. They think "what is late", then
// "what is happening on the third floor", then "what have I got the sparks
// booked for". Three groupings, one list.

enum DLGrouping: String, CaseIterable, Identifiable, Hashable {
    case date, location, trade, assignee

    var id: String { rawValue }
    var label: String {
        switch self {
        case .date:     return "Date"
        case .location: return "Floor / area"
        case .trade:    return "Trade"
        case .assignee: return "Who"
        }
    }
    var icon: String {
        switch self {
        case .date:     return "calendar"
        case .location: return "building.2.fill"
        case .trade:    return "wrench.and.screwdriver.fill"
        case .assignee: return "person.2.fill"
        }
    }
}

enum DLFilter: String, CaseIterable, Identifiable, Hashable {
    case all, overdue, thisWeek, atRisk, complete

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:      return "All"
        case .overdue:  return "Overdue"
        case .thisWeek: return "This week"
        case .atRisk:   return "At risk"
        case .complete: return "Complete"
        }
    }
}

struct DLGroup: Identifiable {
    let id: String
    let title: String
    let items: [DLDeadline]
    var accent: Color? = nil
}

// MARK: - Store
//
// Swap the sample array for your real source. Everything below the `items`
// property is presentation logic the screens call directly.

final class DLStore: ObservableObject {

    @Published var items: [DLDeadline]
    @Published var grouping: DLGrouping = .date
    @Published var filter: DLFilter = .all
    @Published var search: String = ""
    @Published var tradeFilter: String = "All trades"

    var now: Date = Date()
    /// When set (operative mode), stats and lists only include deadlines assigned to this user.
    var restrictToAssigneeUserId: String? = nil
    /// Called after every mutation so the host can persist + reschedule notifications.
    var onItemsChanged: (([DLDeadline]) -> Void)? = nil

    init(items: [DLDeadline] = DLStore.sample()) {
        self.items = items
    }

    var scopedItems: [DLDeadline] {
        guard let uid = restrictToAssigneeUserId, !uid.isEmpty else { return items }
        return items.filter { $0.assigneeUserIds.contains(uid) }
    }

    // Counts for the stat tiles and the segment badges.
    var overdueCount: Int  { scopedItems.filter { $0.urgency(now: now).isOverdue }.count }
    var thisWeekCount: Int { scopedItems.filter { let d = $0.daysRemaining(now: now)
                                            return $0.status != .complete && d >= 0 && d <= 7 }.count }
    var atRiskCount: Int   { scopedItems.filter { $0.isAtRisk(now: now) }.count }
    var completeCount: Int { scopedItems.filter { $0.status == .complete }.count }
    var criticalOpen: Int  { scopedItems.filter { $0.isCritical && $0.status != .complete }.count }

    var completionRatio: Double {
        guard !scopedItems.isEmpty else { return 0 }
        return Double(completeCount) / Double(scopedItems.count)
    }

    var trades: [String] {
        ["All trades"] + Set(scopedItems.compactMap(\.trade)).sorted()
    }

    /// Number of open deadlines falling on a given day — drives the week rail.
    func load(on day: Date) -> Int {
        let cal = Calendar.current
        return scopedItems.filter { $0.status != .complete && cal.isDate($0.due, inSameDayAs: day) }.count
    }

    func hasOverdue(on day: Date) -> Bool {
        let cal = Calendar.current
        return scopedItems.contains { $0.urgency(now: now).isOverdue && cal.isDate($0.due, inSameDayAs: day) }
    }

    private var filtered: [DLDeadline] {
        scopedItems.filter { item in
            // Segment
            switch filter {
            case .all:      break
            case .overdue:  if !item.urgency(now: now).isOverdue { return false }
            case .thisWeek: let d = item.daysRemaining(now: now)
                            if item.status == .complete || d < 0 || d > 7 { return false }
            case .atRisk:   if !item.isAtRisk(now: now) { return false }
            case .complete: if item.status != .complete { return false }
            }
            // Trade chip
            if tradeFilter != "All trades" && item.trade != tradeFilter { return false }
            // Search covers title, location, trade and assignee
            if !search.isEmpty {
                let hay = [item.title, item.location ?? "", item.trade ?? "",
                           item.company ?? "", item.assignees.joined(separator: " ")]
                    .joined(separator: " ").lowercased()
                if !hay.contains(search.lowercased()) { return false }
            }
            return true
        }
    }

    /// The grouped, sorted list the screen renders.
    func groups() -> [DLGroup] {
        let list = filtered
        switch grouping {
        case .date:     return dateGroups(list)
        case .location: return keyed(list, key: { $0.location ?? "Unassigned area" }, icon: nil)
        case .trade:    return keyed(list, key: { $0.trade ?? "No trade" }, icon: nil)
        case .assignee: return keyed(list, key: { $0.assignees.first ?? "Unassigned" }, icon: nil)
        }
    }

    private func dateGroups(_ list: [DLDeadline]) -> [DLGroup] {
        var buckets: [(String, Color?, [DLDeadline])] = [
            ("Overdue",   HS.red,   []),
            ("Today",     HS.amber, []),
            ("Tomorrow",  HS.amber, []),
            ("This week", HS.blue,  []),
            ("Next week", HS.slate, []),
            ("Later",     HS.slate, []),
            ("Complete",  HS.green, [])
        ]
        for item in list {
            let d = item.daysRemaining(now: now)
            let idx: Int
            if item.status == .complete { idx = 6 }
            else if d < 0   { idx = 0 }
            else if d == 0  { idx = 1 }
            else if d == 1  { idx = 2 }
            else if d <= 7  { idx = 3 }
            else if d <= 14 { idx = 4 }
            else            { idx = 5 }
            buckets[idx].2.append(item)
        }
        return buckets.compactMap { bucket -> DLGroup? in
            guard !bucket.2.isEmpty else { return nil }
            return DLGroup(id: bucket.0,
                           title: bucket.0,
                           items: bucket.2.sorted { $0.due < $1.due },
                           accent: bucket.1)
        }
    }

    private func keyed(_ list: [DLDeadline],
                       key: (DLDeadline) -> String,
                       icon: String?) -> [DLGroup] {
        Dictionary(grouping: list, by: key)
            .map { k, v in
                DLGroup(id: k,
                        title: k,
                        items: v.sorted {
                            $0.urgency(now: now).rank == $1.urgency(now: now).rank
                                ? $0.due < $1.due
                                : $0.urgency(now: now).rank < $1.urgency(now: now).rank
                        })
            }
            .sorted { a, b in
                // Groups containing the most urgent item float to the top.
                let ra = a.items.first?.urgency(now: now).rank ?? 99
                let rb = b.items.first?.urgency(now: now).rank ?? 99
                return ra == rb ? a.title < b.title : ra < rb
            }
    }

    /// Timeline rows: everything open, sorted by start then due.
    func timelineItems() -> [DLDeadline] {
        filtered.filter { $0.status != .complete }
                .sorted { ($0.start ?? $0.due) < ($1.start ?? $1.due) }
    }

    func predecessors(of item: DLDeadline) -> [DLDeadline] {
        items.filter { item.dependsOn.contains($0.id) }
    }

    func dependents(of item: DLDeadline) -> [DLDeadline] {
        items.filter { $0.dependsOn.contains(item.id) }
    }

    // MARK: Mutations

    func reschedule(_ item: DLDeadline, to newDate: Date, reason: String, author: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let old = items[i].due
        if items[i].originalDue == nil { items[i].originalDue = old }
        items[i].due = newDate
        items[i].history.insert(
            DLChange(at: Date(), author: author,
                     kind: .rescheduled(from: old, to: newDate, reason: reason)),
            at: 0)
        notifyChange()
    }

    func setProgress(_ item: DLDeadline, to pct: Int, author: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].progress = Double(pct) / 100
        if pct > 0 && items[i].status == .notStarted { items[i].status = .inProgress }
        items[i].history.insert(DLChange(at: Date(), author: author, kind: .progress(to: pct)), at: 0)
        notifyChange()
    }

    func complete(_ item: DLDeadline, author: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].status = .complete
        items[i].progress = 1
        items[i].completedAt = Date()
        items[i].history.insert(DLChange(at: Date(), author: author, kind: .completed(on: Date())), at: 0)
        notifyChange()
    }

    func upsert(_ item: DLDeadline) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.insert(item, at: 0)
        }
        notifyChange()
    }

    func replaceAll(_ newItems: [DLDeadline]) {
        items = newItems
    }

    private func notifyChange() {
        onItemsChanged?(items)
    }
}

// MARK: - Sample data
//
// Dated relative to today so the previews always show a live spread of
// overdue / due / upcoming rather than going stale.

extension DLStore {
    static func sample() -> [DLDeadline] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func d(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

        let firstFix = DLDeadline(
            title: "3rd Floor WC 1st Fix",
            location: "3rd Floor",
            trade: "Plumbing & Gas",
            detail: "Carcass all WC pods, soil connections tested and capped ready for boarding.",
            start: d(-10), due: d(4),
            assignees: ["Dan Whelan", "Marek Kowal"],
            company: "Hydro M&E Ltd",
            status: .inProgress, progress: 0.45, isCritical: true,
            history: [
                DLChange(at: d(-1), author: "Farnie Nel", kind: .progress(to: 45)),
                DLChange(at: d(-10), author: "Farnie Nel", kind: .created(due: d(4)))
            ])

        let boarding = DLDeadline(
            title: "3rd Floor WC Boarding",
            location: "3rd Floor",
            trade: "Drylining",
            start: d(4), due: d(11),
            assignees: ["Tomas Silva"],
            company: "Linex Interiors",
            status: .notStarted, progress: 0,
            dependsOn: [firstFix.id])

        return [
            firstFix,
            boarding,
            DLDeadline(title: "2nd Floor Containment Complete",
                       location: "2nd Floor", trade: "Electrical",
                       start: d(-18), due: d(-3),
                       assignees: ["Ryan Cole"], company: "Voltix Electrical",
                       status: .inProgress, progress: 0.8, isCritical: true,
                       originalDue: d(-8),
                       history: [
                        DLChange(at: d(-9), author: "Farnie Nel",
                                 kind: .rescheduled(from: d(-8), to: d(-3),
                                                    reason: "Cable tray delivery short")),
                        DLChange(at: d(-18), author: "Farnie Nel", kind: .created(due: d(-8)))
                       ]),
            DLDeadline(title: "Riser 2 Fire Stopping Sign-off",
                       location: "Risers", trade: "General",
                       start: d(-6), due: d(0),
                       assignees: ["Ellie Marsh"], company: "RED Construction",
                       status: .inProgress, progress: 0.6),
            DLDeadline(title: "Level 1 Screed Pour",
                       location: "1st Floor", trade: "Groundworks",
                       start: d(-2), due: d(1),
                       assignees: ["Paul Enright"], company: "Castle Screeds",
                       status: .blocked, progress: 0.2,
                       blockedReason: "Awaiting UFH pressure test certificate"),
            DLDeadline(title: "Roof Edge Protection Strike",
                       location: "Roof", trade: "Scaffolding",
                       start: d(6), due: d(14),
                       assignees: ["Jonno Peart"], company: "Apex Access",
                       status: .notStarted, progress: 0),
            DLDeadline(title: "Ground Floor Reception Joinery",
                       location: "Ground Floor", trade: "Joinery",
                       start: d(2), due: d(21),
                       assignees: ["Sam Idris"], company: "Fineline Joinery",
                       status: .notStarted, progress: 0),
            DLDeadline(title: "2nd Floor WC 1st Fix",
                       location: "2nd Floor", trade: "Plumbing & Gas",
                       start: d(-24), due: d(-12), completedAt: d(-13),
                       assignees: ["Dan Whelan"], company: "Hydro M&E Ltd",
                       status: .complete, progress: 1,
                       history: [DLChange(at: d(-13), author: "Dan Whelan", kind: .completed(on: d(-13)))])
        ]
    }
}
