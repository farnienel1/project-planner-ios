# Project Planner iOS

The rules live in the files below. This file only imports them, so there is still one rulebook.

@AGENTS.md
@docs/agent-rules/canonical-architecture.md
@docs/agent-rules/advisor.md

The two files in `docs/agent-rules/` are symlinks to `.cursor/rules/canonical-architecture.mdc` and `.cursor/rules/advisor.mdc`. Edit the `.mdc` files.

Read `docs/CANONICAL_ARCHITECTURE.md` before changing bookings, warnings, invoicing, labour, organisation context, dates, people, invites, notifications, or billing.

Read `.cursor/rules/ios-testing.mdc` before running or writing tests.

## Always

1. Shared rules come from `Project Planner/Canonical/CanonicalBusinessEngine.swift`, which runs `Project Planner/Canonical/canonical-business.js`. Search it and call the existing function first. Name the function you used in your report.
2. Never hand-edit `canonical-business.js`. Never add a second calculator, status enum, Deleted-user check, or toggle list in a view or store.
3. A new shared rule starts in `project-planner-web` `lib/canonical`. The packed script is copied here and committed. Its sha256 must match `Project Planner/Canonical/canonical-business.js.sha256` here and `lib/canonical/dist/canonical-business.sha256` in the web repo.
4. If web and iOS disagree, trace the first divergence in this order: database, query, organisation context, business rule, date rule, cache, then UI. Never patch a screen's number.
5. SwiftUI layout and navigation stay in this app. Nested-screen parity applies.
