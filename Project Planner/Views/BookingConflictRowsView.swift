//
//  BookingConflictRowsView.swift
//  Project Planner
//
//  Rulebook 1.16.0 §5, §9: one conflict list for the booking flows (web `BookingConflictRows`). Double bookings
//  are orange, annual leave purple (`bookingLeaveConflicts`); pending leave is shown softer. Each row is ticked
//  (book anyway) or ✕ (drop that day for that person); the flow saves only when every row is one or the other, and
//  dropping every day saves nothing. Layout only: the rows come from the rulebook.
//

import Combine
import SwiftUI

enum BookingConflictDecision: Equatable {
    case confirm
    case drop
}

struct BookingConflictItem: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case doubleBooking = "double_booking"
        case annualLeave = "annual_leave"
    }

    /// `personKey|dayKey|kind` (web `conflictRowKey`).
    let id: String
    /// The id the flow books this person under.
    let personKey: String
    let dayKey: String
    let kind: Kind
    let personName: String
    let dayLabel: String
    let detail: String
    /// Annual leave only: pending leave is shown softer.
    let pending: Bool

    var personDayKey: String { "\(personKey)|\(dayKey)" }

    static func key(personKey: String, dayKey: String, kind: Kind) -> String {
        "\(personKey)|\(dayKey)|\(kind.rawValue)"
    }

    /// A purple row from a `bookingLeaveConflicts` result.
    static func leave(_ row: BookingLeaveConflict, personName: String) -> BookingConflictItem {
        BookingConflictItem(
            id: key(personKey: row.personId, dayKey: row.dayKey, kind: .annualLeave),
            personKey: row.personId,
            dayKey: row.dayKey,
            kind: .annualLeave,
            personName: personName,
            dayLabel: dayLabel(row.dayKey),
            detail: row.detail,
            pending: row.isPending
        )
    }

    /// An orange double-booking row (web `BookingConflictRows` "Already booked"): the same component and decisions as
    /// the leave rows.
    static func doubleBooking(personKey: String, dayKey: String, personName: String, detail: String) -> BookingConflictItem {
        BookingConflictItem(
            id: key(personKey: personKey, dayKey: dayKey, kind: .doubleBooking),
            personKey: personKey,
            dayKey: dayKey,
            kind: .doubleBooking,
            personName: personName,
            dayLabel: dayLabel(dayKey),
            detail: detail,
            pending: false
        )
    }

    /// "Tue 4 Nov" in the organisation zone.
    static func dayLabel(_ dayKey: String) -> String {
        guard let date = OrganizationRulebookContext.date(fromDayKey: dayKey) else { return dayKey }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = OrganizationRulebookContext.timeZone
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }
}

enum BookingConflictResolution {
    /// True when every row is ticked or dropped (web `conflictsResolved`).
    static func resolved(_ rows: [BookingConflictItem], decisions: [String: BookingConflictDecision]) -> Bool {
        rows.allSatisfy { decisions[$0.id] != nil }
    }

    /// `personKey|dayKey` pairs the booker dropped (web `droppedPersonDays`).
    static func droppedPersonDays(_ rows: [BookingConflictItem], decisions: [String: BookingConflictDecision]) -> Set<String> {
        Set(rows.filter { decisions[$0.id] == .drop }.map(\.personDayKey))
    }
}

/// The heading, legend and rows with ✓ / ✕.
struct BookingConflictRowsView: View {
    let rows: [BookingConflictItem]
    @Binding var decisions: [String: BookingConflictDecision]
    var showHeading = true

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if showHeading {
                    Text(CanonicalBusinessEngine.bookingConflictsHeading)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    BookingConflictLegend()
                }
                ForEach(rows) { row in
                    BookingConflictRowView(row: row, decision: decisions[row.id]) { decision in
                        decisions[row.id] = decision
                    }
                }
            }
        }
    }
}

struct BookingConflictLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            legendDot(ProjectWorksRevampColors.clashOrange, "Already booked")
            legendDot(ProjectWorksRevampColors.leavePurple, "Annual leave")
        }
        .font(.system(size: 11))
        .foregroundStyle(ProjectWorksRevampColors.muted)
    }

    private func legendDot(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title)
        }
    }
}

struct BookingConflictRowView: View {
    let row: BookingConflictItem
    let decision: BookingConflictDecision?
    let onDecide: (BookingConflictDecision) -> Void

    private var isLeave: Bool { row.kind == .annualLeave }
    private var tone: Color { isLeave ? ProjectWorksRevampColors.leavePurple : ProjectWorksRevampColors.clashOrange }
    private var tint: Color { isLeave ? ProjectWorksRevampColors.leavePurpleTint : ProjectWorksRevampColors.clashOrangeTint }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(tone).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(row.personName) · \(row.dayLabel)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(decision == .drop ? ProjectWorksRevampColors.muted : ProjectWorksRevampColors.ink)
                    .strikethrough(decision == .drop)
                Text(row.detail + (decision == .confirm ? " · confirmed" : decision == .drop ? " · day dropped" : ""))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(decision == .drop ? ProjectWorksRevampColors.muted : tone)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                decisionButton(symbol: "xmark", color: .red, selected: decision == .drop, label: "Drop \(row.dayLabel) for \(row.personName)") {
                    onDecide(.drop)
                }
                .accessibilityIdentifier("bookingConflict.\(row.id).drop")
                decisionButton(symbol: "checkmark", color: ProjectWorksRevampColors.blueFill, selected: decision == .confirm, label: "Confirm \(row.dayLabel) for \(row.personName)") {
                    onDecide(.confirm)
                }
                .accessibilityIdentifier("bookingConflict.\(row.id).confirm")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(decision == .drop ? ProjectWorksRevampColors.surface : tint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(decision == nil ? tone : ProjectWorksRevampColors.border, lineWidth: 1)
        )
        .opacity(isLeave && row.pending && decision == nil ? 0.8 : 1)
    }

    private func decisionButton(
        symbol: String,
        color: Color,
        selected: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selected ? Color.white : color)
                .frame(width: 32, height: 32)
                .background(Circle().fill(selected ? color : ProjectWorksRevampColors.surface))
                .overlay(Circle().stroke(color, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The conflict list as a confirm step for flows that save from one button (quick add, edit, Daily Overview,
/// Book Labour, My Schedule, manager site bookings). "Book" is enabled once every row is ticked or dropped; the
/// gate's completion gets the dropped `personKey|dayKey` pairs.
@MainActor
final class BookingConflictGate: ObservableObject {
    struct Pending: Identifiable {
        let id = UUID()
        let rows: [BookingConflictItem]
        let onConfirm: (Set<String>) -> Void
    }

    @Published var pending: Pending?

    /// Saves at once when there is nothing to decide; otherwise asks first. `afterDismiss`: the flow's own sheet is
    /// closing, so the list opens a moment later (one sheet at a time).
    func run(
        rows: [BookingConflictItem],
        afterDismiss: Bool = false,
        onConfirm: @escaping (Set<String>) -> Void
    ) {
        if rows.isEmpty {
            onConfirm([])
            return
        }
        let next = Pending(rows: rows, onConfirm: onConfirm)
        if afterDismiss {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                self?.pending = next
            }
        } else {
            pending = next
        }
    }

    /// One booking (one person, one day): saves when nothing clashes or the row is ticked; dropping the day saves
    /// nothing.
    func runSingle(rows: [BookingConflictItem], afterDismiss: Bool = false, save: @escaping () -> Void) {
        run(rows: rows, afterDismiss: afterDismiss) { dropped in
            guard dropped.isEmpty else { return }
            save()
        }
    }
}

struct BookingConflictSheet: View {
    let pending: BookingConflictGate.Pending
    let onDone: () -> Void
    @State private var decisions: [String: BookingConflictDecision] = [:]

    private var resolved: Bool { BookingConflictResolution.resolved(pending.rows, decisions: decisions) }

    var body: some View {
        NavigationStack {
            ScrollView {
                BookingConflictRowsView(rows: pending.rows, decisions: $decisions)
                    .padding(16)
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationTitle("Check these days")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                        .accessibilityIdentifier("bookingConflictSheet.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Book") {
                        let dropped = BookingConflictResolution.droppedPersonDays(pending.rows, decisions: decisions)
                        let confirm = pending.onConfirm
                        onDone()
                        confirm(dropped)
                    }
                    .disabled(!resolved)
                    .accessibilityIdentifier("bookingConflictSheet.book")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension View {
    /// Presents the gate's conflict list when a flow asks for it.
    func bookingConflictSheet(_ gate: BookingConflictGate) -> some View {
        modifier(BookingConflictSheetModifier(gate: gate))
    }
}

private struct BookingConflictSheetModifier: ViewModifier {
    @ObservedObject var gate: BookingConflictGate

    func body(content: Content) -> some View {
        content.sheet(item: $gate.pending) { pending in
            BookingConflictSheet(pending: pending) { gate.pending = nil }
        }
    }
}

/// `bookingLeaveConflicts` for a booking about to be saved, as purple rows (RULEBOOK 1.16.0). Inputs only.
enum BookingLeaveConflictItems {
    struct Booked {
        var person: BookingLeaveConflictInputs.Person
        var name: String
    }

    /// The person behind a week-grid row or picker: books under the first operative id (stored), else the first
    /// users id; every other id is one leave may be stored under.
    static func person(operativeIds: [UUID], userIds: [String], email: String? = nil) -> BookingLeaveConflictInputs.Person {
        let storedOperativeIds = operativeIds.map { Booking.storedOperativeId(for: $0) }
        let id = storedOperativeIds.first ?? userIds.first ?? ""
        return BookingLeaveConflictInputs.Person(
            id: id,
            userId: userIds.first,
            operativeIds: Array(storedOperativeIds.dropFirst()) + userIds.dropFirst(),
            email: email
        )
    }

    static func items(
        booked: [Booked],
        dates: [Date],
        holidays: [HolidayBooking],
        users: [AppUser],
        policy: OrgPayrollTimePolicy,
        timeSlot: String?,
        workStartTime: String? = nil,
        workEndTime: String? = nil
    ) -> [BookingConflictItem] {
        let people = booked.map(\.person).filter { !$0.id.isEmpty }
        let conflicts = BookingLeaveConflictInputs.conflicts(
            people: people,
            dates: dates,
            holidays: holidays,
            users: users,
            policy: policy,
            timeSlot: timeSlot,
            workStartTime: workStartTime,
            workEndTime: workEndTime
        )
        return conflicts.map { row in
            let name = booked.first { $0.person.id == row.personId }?.name ?? "This person"
            return BookingConflictItem.leave(row, personName: name)
        }
    }
}

/// The conflict rows inline in a one-day form (quick add, edit booking): shown under the heading, and the form saves
/// only once each is ticked or dropped. Dropping the day saves nothing.
struct InlineBookingConflicts: View {
    let rows: [BookingConflictItem]
    @Binding var decisions: [String: BookingConflictDecision]

    var body: some View {
        BookingConflictRowsView(rows: rows, decisions: $decisions)
    }
}

extension BookingLeaveConflictItems {
    /// Leave rows for one operative booking as it will be saved (edit booking, Daily Overview change booking).
    static func items(
        for booking: Booking,
        personName: String,
        holidays: [HolidayBooking],
        operatives: [Operative],
        users: [AppUser],
        policy: OrgPayrollTimePolicy
    ) -> [BookingConflictItem] {
        items(
            booked: [Booked(
                person: BookingLeaveConflictInputs.person(operativeId: booking.operativeId, operatives: operatives, users: users),
                name: personName
            )],
            dates: [booking.date],
            holidays: holidays,
            users: users,
            policy: policy,
            timeSlot: booking.timeSlot.rawValue,
            workStartTime: booking.workStartTime,
            workEndTime: booking.workEndTime
        )
    }

    /// Leave rows for one manager site booking as it will be saved (My Schedule, manager bookings).
    static func items(
        for booking: ManagerSiteBooking,
        personName: String,
        holidays: [HolidayBooking],
        users: [AppUser],
        policy: OrgPayrollTimePolicy
    ) -> [BookingConflictItem] {
        let person = users.first { $0.id == booking.userId }.map { BookingLeaveConflictInputs.person(user: $0) }
            ?? BookingLeaveConflictInputs.Person(id: booking.userId, userId: booking.userId)
        return items(
            booked: [Booked(person: person, name: personName)],
            dates: [booking.date],
            holidays: holidays,
            users: users,
            policy: policy,
            timeSlot: booking.timeSlot.rawValue,
            workStartTime: booking.workStartTime,
            workEndTime: booking.workEndTime
        )
    }
}
