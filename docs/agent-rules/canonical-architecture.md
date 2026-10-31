# Canonical business logic

The rules are `docs/RULEBOOK.md`. It is a byte-identical mirror of `docs/RULEBOOK.md` in `project-planner-web`, copied with the packed script by `scripts/sync-rulebook-from-web.sh`. Never edit the mirror, `Project Planner/Canonical/canonical-business.js`, its `.sha256` or `canonical-manifest.json` here; `RulebookParityTests` and the Stop hook (`scripts/rulebook-guard.sh`) fail when they drift.

Before adding or changing any rule the rulebook owns:

1. Name the rulebook function the change calls through `CanonicalBusinessEngine`, or state that none exists.
2. If none exists, the rule is added to web `lib/canonical` first, the rulebook version is bumped, and this repo syncs. Swift never gets its own version.
3. Every web-side gap or rule question goes into the report for the web agent. Never fix it by diverging on iOS.

SwiftUI layout and navigation stay in this app.
