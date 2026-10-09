# Canonical architecture

The executable business rules live in the web repository at `lib/canonical/engine.ts`. This app does not keep a second copy of those rules.

| Piece | Path |
|---|---|
| Script the app runs | `Project Planner/Canonical/canonical-business.js` |
| Swift entry | `Project Planner/Canonical/CanonicalBusinessEngine.swift` |
| Warning scans | `WarningsService` and `WarningsRefreshHelper` ask `CanonicalBusinessEngine.warningBounds`. Qualification, unverified, and unbooked rows come from `qualificationExpiryRows`, `unverifiedOperativeRows`, and `unbookedLabourRows` in that script. Full week is Monday–Friday. Unbooked means the bookings do not cover the organisation standard day; the payload must include each booking’s `timeSlot`, `workStart`, and `workEnd`, plus `standardDayStart`, `standardDayEnd`, `breakWindowStart`, and `breakWindowEnd`. |
| Invoicing default | Half-month ranges (1–15 and 16–31), same as the canonical module. `InvoicingPeriodResolver` defaults to the `Europe/London` calendar. |
| Organisation context | `FirebaseBackend.currentOrganization`. Switching replaces `organizationSwitchToken` and ignores an organisation-document snapshot whose id is no longer current. |
| Cache | `SmartCacheService` stores each company under its own key. |
| Persistence | `PersistenceService` keys UserDefaults by user id and `cached_organizationId`. |
| Security rules | `Project Planner/firestore.rules`. `canAccessOrganization` is membership in that company only. |
| Agent rules | `AGENTS.md` |

Rebuild the script from the web repo with `npm run build:canonical` and commit `canonical-business.js`. Do not edit the script by hand.

Manager catalogue visibility is not in the script. In Swift, a manager sees every project and every small works job, including jobs they are not assigned to. `permissions.projects` and `permissions.smallWorks` hide create and edit only. Super admin ignores those two toggles. Staff warning rows are the same canonical list for admins and managers. One email is one person: Swift sends the finished account with the smaller id first and repeats that person row under every alias id. Since script `315d73c4…` (web branch `cursor/warning-coverage-rulebook-530e`), `unbookedLabourRows` builds an email to user-id map from those rows and looks up manager bookings and approved holidays on every id that shares the email, so an alias that holds the hours or the leave covers the day. Swift still drops a full-day unbooked row when that email's paid hours already cover the standard day. `excludedUserIdsFromUnbookedWarnings` still filters warning rows only. Do not hand-edit the script. A notification for a job still goes to the line manager or the assigned project manager, not to every manager. The web bundle must catch up if it still hides those lists or warning rows by assignment.

Clash timelines and the material cut-off message still live in `Core/WarningsComputation.swift`. Those dates use `CanonicalBusinessEngine.businessCalendar`, not `Calendar.current`. Payroll overtime still lives in `Core/PayrollHoursEngine.swift`. Named `FULL DAY`, `AM`, and `PM` hours are defined in the canonical script (`paidHoursForNamedSlot`): a half day pays half the standard paid hours whatever its clock window.

## Standard day, AM and PM

The standard day and its two halves come from the script. `CanonicalBusinessEngine.halfDayWindows(CanonicalStandardDayInput)` returns the day, `am`, `pm`, the `pivot` (`break` or `midpoint`), and the break. The organisation policy fields go through unchanged; the script applies the 07:30–16:00 and 12:00–12:30 fallbacks. With the default policy AM is 07:30–12:00 and PM is 12:30–16:00. A company whose break is not usable (outside the day, or under an hour from either end) is split at the wall-clock midpoint. There is no Swift copy of that split; `PayrollTimePolicyCatalog.weekdayHalfDayWindows` is gone. The day input is always `CanonicalStandardDayInput(policy:)`, the weekday standard day and break, on Saturday and Sunday too, the same input the web app feeds in. Weekend custom windows and all-hours-at-multiplier stay in `timelinePolicy` for pay and drawing; they do not change the shared split.

The other wrappers in that file are `slotInterval` (the interval a booking occupies), `namedSlotKind`, `standardDayWindow`, `standardBreakWindow`, `mergeMinuteIntervals`, and `subtractMinuteIntervals`. `halfDayWindows` and `slotInterval` memoise script results per distinct input because clash and sort loops call them; the cache holds answers, not a rule.

Clash, sort, and calendar export (`OperativeBookingInterval.clashInterval`, `ManagerScheduleInterval.clashInterval`, `Booking` and `ManagerSiteBooking` `minutesSortKey` and `calendarBlock`, `HomeUpNextSupport.sortDate`) call `slotInterval` with the stored slot and the stored clock times and use the result as-is. Clock times win; the named slot applies only when the script rejects the clock pair (missing, unparsable, or end not after start). Swift has no "AM means the half even when clocks differ" branch and no local clock parsing on that path. Overnight clash extension is not implemented in Swift: an end before the start falls through to the named slot, as in the script. `PayrollHoursEngine.matchesStandardHalfWindow`, `PayrollPolicyBookingRecalibrator`, the Book Labour quick AM/PM draft, and the My Schedule default times take the halves from `halfDayWindows` or `slotInterval` with the same weekday input. The one Swift-only overnight rule left is pay: `PayrollHoursEngine.overnightWallResult` and `Booking.totalBookedHours` (via `clockSpanMinutes`) still count 22:00–02:00 as four hours.

## Annual leave against bookings

`CanonicalBusinessEngine.leaveCoverageRows(CanonicalLeaveCoverageInput)` returns the script's `leave_clash` rows (a booking inside approved leave) and `leave_cover` rows (half-day leave whose other half is not fully booked, with the clock ranges still open and their hours). People are keyed by `personKey` with their user id and every linked operative id; bookings carry `personId` and `kind` (`operative` or `manager`). The Swift warning screens are not yet reading these rows.

## Dismissed warnings

`CanonicalBusinessEngine.qualificationDismissKey(operativeId:qualificationId:expiryDayKey:)` is the id both apps store a dismissed qualification warning under (`qual|operative|qualification|expiryDay`), and `withoutDismissedQualificationRows` drops only expired rows whose key is dismissed. `qualificationExpiryRows` already returns `dismissKey` on each row.

## Agent windows

A window that only has this repo may change SwiftUI and data loading. Shared results come from `CanonicalBusinessEngine`. Do not edit `canonical-business.js` by hand, and do not add a second calculator for a rule the script already has. A new shared rule is added in `project-planner-web/lib/canonical`, the script is rebuilt, and both copies are committed.

A window that only has the web repo may change `lib/canonical`. `npm run build:canonical` writes this app's script only when this checkout is at `../project-planner-ios`. If it is not, the file to commit here is the generated `lib/canonical/dist/canonical-business.js` from that web change.

A workspace with both repositories changes the TypeScript, rebuilds, and commits both generated scripts in the same phase.

The full description of what is shared and how a switch works is `docs/CANONICAL_ARCHITECTURE.md` in `project-planner-web`.
