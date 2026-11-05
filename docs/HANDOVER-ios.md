# iOS handover — 2026-11-05 ~15:30 UTC

Written by the iOS-only Claude session before iPhone work moves into one combined web + iPhone chat. Nothing in this session is uncommitted or unpushed: everything is on the branches below.

## Branches and PRs

| Repo | Branch | State |
|---|---|---|
| project-planner-ios | `main` | `019ea0a`, rulebook **1.31.1** (#191). |
| project-planner-ios | `claude/nifty-lovelace-76ztr2` | Draft PR [#192](https://github.com/farnienel1/project-planner-ios/pull/192), 2 commits on `main`: `306617f` (1.31.3 mirror) and `29e963b` (version test fix). |
| project-planner-ios | `main-vr2rt0-uoqzwv` | The pre-squash branch of #191 (same content as `main`) plus this note. Holds no other work. |
| project-planner-web | `claude/nifty-lovelace-76ztr2` | At `a8a71ba` (1.31.3, #278); no local changes. Web `main` has moved on (see below). |

## Result of the 1.31.3 rulebook sync (#192)

- `scripts/sync-rulebook-from-web.sh` from web `a8a71ba`. Changed: `Project Planner/Canonical/canonical-business.js` (only the `rulebookStamp()` version and sha), its `.sha256`, `canonical-manifest.json`, `docs/RULEBOOK.md`. Parity fixture and cross-platform contract unchanged.
- Hashes matched the hand-off: packed script `0e947e88f66e0a57fe0d872c48e5c0bc47d92df721562c68ccfd5201efda0400`, rulebook `0b2674347e478136cb6848884df6a4789b7202c9ab8d1195271260e2d9958920`, contract `7f70ec28…e126`.
- 1.31.2 and 1.31.3 change only web `firestore.rules` (type-check fixes, compile-cost restructure). No iOS behaviour change, no exports added or removed.
- CI: first `parity-tests` run failed on 1 of 917 tests, `Rulebook1311Tests.testRulebookVersionIs1311` (it pinned the version to 1.31.1). Fixed in `29e963b`: the version check moved to new `ProjectPlannerTests/Rulebook1313Tests.swift`. The re-run of `parity-tests` was **still in progress** when this note was written; `mirror-intact`, `gitleaks` and `pr-body` passed. Check #192 before merging.
- Convention learned: only the newest `RulebookNNNNTests.swift` pins `rulebookStamp()?.version`. Every sync that moves the version must move that assertion, or `parity-tests` fails.

## iOS is behind web

- Web `main` is now **1.32.1** (web PR #274, plus Home restyle #276). Packed hash `427d4d314c22ce2a8b3b039cd0a64523fae8b0e824e1d05eb1aa7f25eca669fd`, rulebook sha256 `5df16b5a6ae38eefabbf46b43b704dd6e38f8784ca1e3a428cbb5e6ad7a8c0e1`.
- 1.32.1 itself is rules-only, but **1.32.0 changes behaviour** (overtime and price work / expenses review, multiplier at create, PAYE payday, pay visibility, rulebook version in Settings, own-sheet export notice). Not synced on purpose: start with web `docs/ios-handoff/v1.32.0.md` and `LATEST.md`, run the sync, write a Gap Report and wait for owner approval before implementing. I did not read `v1.32.0.md`; the list above comes from `docs/OWNER_DECISIONS.md` and the PR title.
- Decide whether to merge #192 first or let the 1.32.1 sync supersede it.

## Already done on iOS (calls verified to exist, not every screen re-tested)

1.31.0 people and access (#187): `warningScopeFor` with `jobs` / `managers` / `roster`, `lineManagerChangeBlock`, `jobManagerRemovalWrites`, `superAdminTransferWrites`, `userActiveWrites`, `exportedTimesheetHistorySubjects`; never delete leave. 1.31.1 invitation queries (#191).

## Owner actions outstanding

- Publish Firestore rules from web `main` (now 1.32.1): `firebase deploy --only firestore:rules --project project-planner-f986c`. Live rules are still 1.30.2, so the operatives-manager → admin privilege hole stays open until then.
- Raise `minimumIosBuild` before 1.32 behaviour is switched on.
- Turn on `privatePay` before launch (after `minimumIosBuild` is at least the iOS 1.26.0 build).
- Confirm the #262 judgement call (an operative with a login but no Operatives row is booked under their users id).

## Environment note

The cloud container cannot run Xcode. iOS tests run only in CI (`parity-tests` on the PR).
