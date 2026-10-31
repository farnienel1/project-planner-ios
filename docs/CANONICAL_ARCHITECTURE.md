# Canonical architecture (iOS)

This file is a pointer. The boundary is described once, in web: `docs/CANONICAL_ARCHITECTURE.md` in `project-planner-web`. The rules are `docs/RULEBOOK.md` here, a byte-identical mirror of web's (`scripts/sync-rulebook-from-web.sh`).

| Piece | Path |
|---|---|
| Rule text (mirror, never edited here) | `docs/RULEBOOK.md` |
| Packed script (generated in web) | `Project Planner/Canonical/canonical-business.js` |
| Its hash and manifest | `Project Planner/Canonical/canonical-business.js.sha256`, `Project Planner/Canonical/canonical-manifest.json` |
| Swift entry | `Project Planner/Canonical/CanonicalBusinessEngine.swift` (`rulebookStamp()` gives the version it runs) |
| Parity tests | `ProjectPlannerTests/RulebookParityTests.swift`, `ProjectPlannerTests/CanonicalParityFixtureTests.swift` (fixture mirrored from web `lib/canonical/parity-fixture.json`) |
| Drift guards | `scripts/rulebook-guard.sh` (Claude Code hooks in `.claude/settings.json`), `.github/workflows/rulebook.yml` |
| Security rules | Deployed only from `project-planner-web/firestore.rules` |

To take a new rulebook version: run `scripts/sync-rulebook-from-web.sh`, run the tests, then follow web `docs/ios-handoff/LATEST.md`.
