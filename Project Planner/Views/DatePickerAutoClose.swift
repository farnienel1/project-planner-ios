import SwiftUI

// Owner report 25 Nov: tapping a day in a calendar should pick it and close the calendar, not leave it open until the
// person taps somewhere else. Display only: the selected date, its binding and every write are unchanged.
//
// - `closesCalendarOnDayPick(_:)` is for a compact (default style) date picker, whose calendar is a system popover
//   SwiftUI cannot close directly: the picker is given an identity made from the selected day, so picking another day
//   rebuilds it and the popover closes. Moving between months, or a time-only change, keeps the same day and the same
//   identity, so the calendar stays open.
// - `onDayPicked(_:perform:)` is for a graphical calendar shown in an expandable section or a sheet: it runs `perform`
//   (the caller closes the section or sheet) when the selected day changes.
//
// The day is read in the calendar and time zone the picker itself uses (its environment), so apply either modifier
// directly on the `DatePicker`, before any `.environment(\.calendar / \.timeZone)` it is given.

/// The calendar day of `date` in `calendar` / `timeZone`, as "yyyy-m-d".
func datePickerDayKey(_ date: Date, calendar: Calendar, timeZone: TimeZone) -> String {
    var cal = calendar
    cal.timeZone = timeZone
    let parts = cal.dateComponents([.year, .month, .day], from: date)
    return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
}

private struct CloseCalendarOnDayPick: ViewModifier {
    let selection: Date
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    func body(content: Content) -> some View {
        content.id(datePickerDayKey(selection, calendar: calendar, timeZone: timeZone))
    }
}

private struct RunOnDayPicked: ViewModifier {
    let selection: Date
    let perform: () -> Void
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    func body(content: Content) -> some View {
        content.onChange(of: datePickerDayKey(selection, calendar: calendar, timeZone: timeZone)) { _, _ in
            perform()
        }
    }
}

extension View {
    /// A compact date picker's calendar popover closes once a different day is tapped.
    func closesCalendarOnDayPick(_ selection: Date) -> some View {
        modifier(CloseCalendarOnDayPick(selection: selection))
    }

    /// Runs `perform` when the selected day changes (a graphical calendar in a section or sheet closes itself).
    func onDayPicked(_ selection: Date, perform: @escaping () -> Void) -> some View {
        modifier(RunOnDayPicked(selection: selection, perform: perform))
    }
}
