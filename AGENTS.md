# Project Planner iOS

Business rules shared with the web app are not reimplemented here.

The source is `lib/canonical/engine.ts` in `project-planner-web`. This app runs the generated `Project Planner/Canonical/canonical-business.js` through `Project Planner/Canonical/CanonicalBusinessEngine.swift`. Read `docs/CANONICAL_ARCHITECTURE.md` before changing bookings, warnings, invoicing, labour, organisation context, or dates.

## Rules

1. Canonical business logic. Search `CanonicalBusinessEngine` and the web `lib/canonical` module before adding a business rule. Do not add a parallel calculator in a view or store.
2. Organisation context. Organisation-scoped work uses `FirebaseBackend.currentOrganization`. Do not read another company's cache, UserDefaults blob, or listener after a switch.
3. Architectural changes. A change to shared behaviour is made in `lib/canonical` and the generated script is committed. Update `docs/CANONICAL_ARCHITECTURE.md` in both repositories.
4. New business logic. A rule both apps must share is added to the canonical TypeScript module, then called from Swift. Screens and navigation stay in SwiftUI.
5. Discrepancies. If web and iOS disagree, find the first divergence. Do not change a count on one screen to match the other.
6. Regression tests. A cross-platform discrepancy gets a test against the canonical module (`lib/canonical/canonical.test.ts` in the web repo) and, when the Swift call site is involved, a test in `ProjectPlannerTests`.

`canAccessOrganization` in `Project Planner/firestore.rules` is membership in that organisation. Do not grant access because the organisation document exists or because the user is an admin of a different company.
