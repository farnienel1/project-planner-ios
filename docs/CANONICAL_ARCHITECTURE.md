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

Clash timelines and the material cut-off message still live in `Core/WarningsComputation.swift`. Those dates use `CanonicalBusinessEngine.businessCalendar`, not `Calendar.current`. Payroll overtime still lives in `Core/PayrollHoursEngine.swift`. Named `FULL DAY`, `AM`, and `PM` hours are defined in the canonical script.

## Agent windows

A window that only has this repo may change SwiftUI and data loading. Shared results come from `CanonicalBusinessEngine`. Do not edit `canonical-business.js` by hand, and do not add a second calculator for a rule the script already has. A new shared rule is added in `project-planner-web/lib/canonical`, the script is rebuilt, and both copies are committed.

A window that only has the web repo may change `lib/canonical`. `npm run build:canonical` writes this app's script only when this checkout is at `../project-planner-ios`. If it is not, the file to commit here is the generated `lib/canonical/dist/canonical-business.js` from that web change.

A workspace with both repositories changes the TypeScript, rebuilds, and commits both generated scripts in the same phase.

The full description of what is shared and how a switch works is `docs/CANONICAL_ARCHITECTURE.md` in `project-planner-web`.
