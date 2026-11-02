# Project Planner iOS

Business rules shared with the web app are not reimplemented here.

The rules are `docs/RULEBOOK.md`: a byte-identical mirror of `docs/RULEBOOK.md` in `project-planner-web`, which is canonical. It is never edited here. `scripts/sync-rulebook-from-web.sh` copies it with the packed script (`lib/canonical` → `Project Planner/Canonical/canonical-business.js`, its `.sha256`, `canonical-manifest.json`) and the parity fixture; `RulebookParityTests` and the Stop hook fail when the mirror drifts. This app runs the script through `Project Planner/Canonical/CanonicalBusinessEngine.swift`. Read `docs/RULEBOOK.md` before changing bookings, warnings, invoicing, labour, organisation context, dates, people, invites, notifications or pay.

Every web-side gap or rule question found here is reported to the web agent, never fixed by diverging on iOS.

## Rule 0: the rulebook comes first

The canonical rulebook (`project-planner-web/lib/canonical`, run here as `canonical-business.js` through `CanonicalBusinessEngine`) is the single source of business behaviour for both apps. Before any change that decides who sees what, what is counted, what is written to Firestore, or how a date, booking, warning, timesheet, invite, notification, or permission behaves:

- Name the rulebook function the change calls, or state that none exists.
- If none exists, the rule is added to `lib/canonical` first, the script is rebuilt, and Swift calls it. Swift never gets its own version, not even as a stopgap.
- A screen or store only passes inputs to the rulebook and shows its result.
- A plan, review, or hand-off that touches business behaviour names the rulebook functions it relies on.

## Rules

1. Canonical business logic. Search `CanonicalBusinessEngine` and the web `lib/canonical` module before adding a business rule. Do not add a parallel calculator in a view or store.
2. Organisation context. Organisation-scoped work uses `FirebaseBackend.currentOrganization`. Do not read another company's cache, UserDefaults blob, or listener after a switch.
3. Architectural changes. A change to shared behaviour is made in web `lib/canonical` with a rulebook version bump; this repo then runs `scripts/sync-rulebook-from-web.sh` and commits the mirrored files. The boundary is described in web `docs/CANONICAL_ARCHITECTURE.md`; the iOS file only points to it.
4. New business logic. A rule both apps must share is added to the canonical TypeScript module, then called from Swift. Screens and navigation stay in SwiftUI. Qualification, unverified, and unbooked warning rows already have functions in that script. Call `CanonicalBusinessEngine` for them.
5. Discrepancies. If web and iOS disagree, find the first divergence. Do not change a count on one screen to match the other.
6. Regression tests. A cross-platform discrepancy gets a test against the canonical module (`lib/canonical/canonical.test.ts` in the web repo) and, when the Swift call site is involved, a test in `ProjectPlannerTests`.

`canAccessOrganization` in `project-planner-web/firestore.rules` is membership in that organisation. Do not grant access because the organisation document exists or because the user is an admin of a different company. Firestore rules, indexes, Storage rules, and Cloud Functions are deployed only from the web repo `project-planner-web` with `firebase deploy`.

An agent window with only this repo does not edit `Project Planner/Canonical/canonical-business.js` by hand. An agent window with only the web repo rebuilds that file with `npm run build:canonical` when `../project-planner-ios` is present. Otherwise this repo runs `scripts/sync-rulebook-from-web.sh` (from `../project-planner-web`, or raw GitHub for a named branch).
