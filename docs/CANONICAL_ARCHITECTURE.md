# Canonical architecture

The executable business rules live in the web repository at `lib/canonical/engine.ts`. This app does not keep a second copy of those rules.

| Piece | Path |
|---|---|
| Script the app runs | `Project Planner/Canonical/canonical-business.js` |
| Swift entry | `Project Planner/Canonical/CanonicalBusinessEngine.swift` |
| Warning scans | `WarningsService` and `WarningsRefreshHelper` ask `CanonicalBusinessEngine.warningBounds` |
| Invoicing default | Half-month ranges (1–15 and 16–31), same as the canonical module. `InvoicingPeriodResolver` defaults to the `Europe/London` calendar. |
| Organisation context | `FirebaseBackend.currentOrganization`. Switching replaces `organizationSwitchToken` and ignores an organisation-document snapshot whose id is no longer current. |
| Cache | `SmartCacheService` stores each company under its own key. |
| Persistence | `PersistenceService` keys UserDefaults by user id and `cached_organizationId`. |
| Security rules | `Project Planner/firestore.rules`. `canAccessOrganization` is membership in that company only. |
| Agent rules | `AGENTS.md` |

Rebuild the script from the web repo with `npm run build:canonical` and commit `canonical-business.js`. Do not edit the script by hand.

Warning row selection still lives in `Core/WarningsComputation.swift`. It must use the canonical window. Payroll overtime still lives in `Core/PayrollHoursEngine.swift`. Named `FULL DAY`, `AM`, and `PM` hours are defined in the canonical script.

The full description of what is shared, how a switch works, and where new rules go is `docs/CANONICAL_ARCHITECTURE.md` in `project-planner-web`.
