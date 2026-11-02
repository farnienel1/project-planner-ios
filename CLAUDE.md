# Project Planner iOS

The rules live in the files below. This file only imports them, so there is still one rulebook.

@AGENTS.md
@docs/agent-rules/canonical-architecture.md
@docs/agent-rules/advisor.md

Read `docs/RULEBOOK.md` (a mirror of web's rulebook — never edit it here) before changing bookings, warnings, invoicing, labour, organisation context, dates, people, invites, notifications, or billing.

Read `docs/agent-rules/ios-testing.md` before running or writing tests.

## Always

1. Shared rules come from `Project Planner/Canonical/CanonicalBusinessEngine.swift`, which runs `Project Planner/Canonical/canonical-business.js`. Search it and call the existing function first. Name the function you used in your report.
2. Never hand-edit `canonical-business.js`. Never add a second calculator, status enum, Deleted-user check, or toggle list in a view or store.
3. A new shared rule starts in `project-planner-web` `lib/canonical` with a rulebook version bump. Take it with `scripts/sync-rulebook-from-web.sh` and commit the mirrored files; `RulebookParityTests` checks the script, `.sha256`, `canonical-manifest.json` and `docs/RULEBOOK.md` against each other.
4. If web and iOS disagree, trace the first divergence in this order: database, query, organisation context, business rule, date rule, cache, then UI. Never patch a screen's number.
5. SwiftUI layout and navigation stay in this app. Nested-screen parity applies.
