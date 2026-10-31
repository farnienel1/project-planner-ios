# Web agent hand-off from the iOS alignment pass (rulebook 1.1.0)

Paste this whole file into the agent working in **project-planner-web**. It comes from the iOS repo (`farnienel1/project-planner-ios`, branch `main-vr2rt0-uoqzwv`) after the iOS app was aligned to rulebook 1.1.0 (web `main-kr70k9` @ `5ec298a`, packed hash `13c1194b…dc0c7`, rulebook sha256 `36f61c97…826c`).

## What iOS did

- Mirrors the 1.1.0 pack exactly (`scripts/sync-rulebook-from-web.sh`; `RulebookParityTests`; Stop hook; `.github/workflows/rulebook.yml` with a daily drift alarm against web `main`'s published `canonical-manifest.json` — it only warns until `main-kr70k9` merges, because `main` has no manifest yet).
- Calls the packed script for: org time zone and currency, write metadata, company details, working hours (apply / schedule / cancel, timeline, limits), payment runs, schedule options, warnings (coverage window with fallback reason, clash scan days, clash keys and approval writes, resolved keys, material cut-off rows), pay (`payRateOnDay`, `readStoredRates`, `exclusiveRates`, `canChangePersonPay`), line managers, passwords, timesheets (PAYE 0 lines, overlaps, leave lines, `workedHoursSplit`, owner/reviewer writes, entry reviews), leave (ranges, decisions, day keys, approvers), notifications (inbox always shows, push gated), booking tombstones and refused replays.
- iOS writes are now partial updates with `updatedBy` / `updatedFrom: "ios"` / server `updatedAt`, except booking tombstones (see 1).

Where iOS needed a rule the pack does not export, the Swift code carries a `RULEBOOK-GAP(<name>)` marker. Each marker is listed below and should become a `lib/canonical` export, after which iOS replaces the Swift stopgap with a call.

## How to handle this hand-off

For every item: decide, change `lib/canonical` (with a `canonical.test.ts` case) and/or `firestore.rules` and/or `docs/RULEBOOK.md`, bump the rulebook version, re-pack, and write the iOS hand-off as usual. Items marked **User decision** were decided by the product owner in the iOS session and should be written into the rulebook as stated.

---

## A. User decisions to put into the rulebook

### 1. Booking tombstones carry no write metadata — User decision (D1)
- **Finding:** §1 says every shared write carries `updatedAt` / `updatedBy` / `updatedFrom`. The tombstone rule (`firestore.rules` ~1043-1059) allows only `bookingId, collection, deletedAt, deletedBy, deletedFrom`, so adding metadata would be refused.
- **Decision:** tombstones are the exception; they carry only their own fields. iOS already writes them that way.
- **Action:** add the exception to RULEBOOK §1 "Writes carry metadata" and §2 "Conflicts".

### 2. Self-booking annual leave and the line-manager requirement — User decision (D5)
- **Decision:** a user with the `annualLeaveSelfBook` permission (admins or managers, not operative mode) books their own leave approved. With the toggle off, their leave must be approved by their line manager, which means **a user with self-book off must have a line manager set up**. Their requests go to the line manager(s), who approve or decline, and the requester gets the decision notification.
- **Today:**
  - The firestore rule `hbCallerSelfBooks` (~1373) still treats "no line manager" as self-booking.
  - There is no canonical export. iOS keeps a Swift stopgap: `RULEBOOK-GAP(canSelfBookAnnualLeave)` in `Project Planner/Core/AnnualLeaveCalendarRules.swift`, meaning `annualLeaveSelfBook && !operativeMode`.
- **Action:**
  - Add `canSelfBookAnnualLeave(user)` to `lib/canonical`.
  - Add a validation export, for example `lineManagerRequiredError(user)`. Manage Users on both apps refuses to save self-book off with no line manager. The prompt also applies when self-book is switched off.
  - Change `hbCallerSelfBooks` to the permission only, not "no line manager".
  - Update RULEBOOK §8 "Line manager", §9 and §16 "Annual leave".
  - Say what happens to existing users with self-book off and no line manager. iOS shows them a notice: "Your requests go to the company admins until a line manager is set". Under the new rule that should become a one-off clean-up list for admins.

### 3. Who sees and decides pending leave — User decision (D6)
- **Decision:** admins and super admins see and may decide every pending request in the organisation (§9 already allows any admin). Line managers see requests where they are in `leaveApproverIds`. Nobody sees or decides their own request.
- **Today:**
  - iOS implements this in `AnnualLeaveApproval.canDecide` / `decidableRequests` (`Core/Rulebook+AnnualLeave.swift`) on top of `leaveApproverIds`.
  - `firestore.rules` `hbCanDecide` starts with `hbIsAdmin() ||`, so an admin may decide their **own** request. That contradicts §8 "Nobody approves their own items".
  - iOS excludes admins in operative mode; `hbIsAdmin` does not.
- **Action:**
  - Add `canDecideLeave(viewer, requester, roster)` / `leaveDecisionQueue(viewer, requests, roster)` exports.
  - Make `hbCanDecide` refuse own requests.
  - Decide the operative-mode admin case.
  - Write it into §9.

### 4. Operative clash grouping export — User decision (D7)
- **Finding:** manager and admin overlaps come from `managerClashGroups`. Operative clashes have no export, so iOS still groups them in Swift (`RULEBOOK-GAP(operativeClashGroups)` in `Core/WarningsComputation.swift`, `overlappingClusters`). Clusters of 3+ bookings key only on bookings A and B.
- **Action:**
  - Add `operativeClashGroups(personDayItems)` returning groups plus `clashPairKey` / `clashResolutionKey` per pair. Define clusters of 3 or more.
  - Use it on web.
  - iOS switches to it on the next sync.

---

## B. Rule or security-rule gaps found while implementing

5. **Un-approving a clash is refused for managers.** `acceptedBookingClashes` delete is admin-only in `firestore.rules`, but §5 says admins and managers approve and un-approve. A manager's un-approve batch from either app is refused. Allow manager deletes, or change §5.
6. **`isClashApproved` treats dismissed as approved.** `resolvedWarningKeys` includes dismissed keys, so a dismissed clash counts as approved and lands in the weekly report's "approved clashes". iOS passes approvals only for that list. Split approved from dismissed in the export.
7. **Managers deleting labour bookings.** `bookings` delete and its tombstone are admin-only. Both apps offer delete to managers, and iOS now shows "Only an organisation admin can delete a labour booking. Ask an admin, or cancel the booking instead." Decide whether operatives-managers may delete, then align the rules, rulebook and UI.
8. **Offline delete.** §2 allows create, edit and cancel offline. iOS also queues a delete, which an operative or manager replay can't complete for `bookings`. Decide whether delete is allowed offline.
9. **A not-found booking edit replay.** iOS treats a replayed edit of a booking that no longer exists as final, the same as permission-denied, so it is never recreated (`RULEBOOK-GAP(bookingReplayNotFound)`). Extend `bookingReplayRefusedIsFinal` or say otherwise.
10. **Offline policy table export.** §2's action → allowed / online-only / read-only table and its three messages are in Swift (`Core/Offline/OfflinePolicy.swift`, `RULEBOOK-GAP(offlinePolicyTable)`, 33 actions with stable string ids). Export it (for example `OFFLINE_POLICY` and `offlineAvailability(action)`) so Android reuses it.
11. **Unbooked scan days export.** There is no export for "which days the unbooked scan covers" (Full week and include-weekends). iOS derives it from `clashScanDays` (`RULEBOOK-GAP(unbookedScanDays)` in `CanonicalBusinessEngine.unbookedLabourWindowEnd`). Export `unbookedScanDays(window)`.
12. **Lookahead fallback notice text.** It is not in the pack; iOS copies web's `warningLookaheadFallbackNotice` text. Export the copy.
13. **Platform-owner email.** `isPlatformOwnerEmail` (password minimum 10) is not in the pack. iOS compares with its own protected email (`RULEBOOK-GAP(isPlatformOwnerEmail)`). Export it, or have `passwordPolicyError` take a `role` rather than an email.
14. **`hasNoLineManager` writes.** iOS doesn't write `hasNoLineManager` in the line-manager patch, and it isn't in the manager-allowed keys of `canManagerUpdateOperativeProfile`. Say where it is written and by whom. Item 2 makes this matter.
15. **Rate cleared vs history.** Clearing a rate writes no `operativeDayRateHistory` row on either app, so `payRateOnDay` keeps paying the last history rate after a clear. Decide whether a clear writes a "rate not set" row.
16. **`ORGANIZATION_DOCUMENT_FIELDS` / `OPERATIONAL_COLLECTION_PATHS`** are exported from `lib/canonical/index.ts` but not from `bundleEntry.ts`, so the packed script lacks them. The 1.1.0 iOS brief told iOS to match them. Add them to `bundleEntry.ts`.
17. **`profilePhotoUpdatedAt`.** Web writes it (`components/settings/SettingsScreen.tsx` ~252), but it isn't in `USER_DOCUMENT_FIELDS` or §12. iOS now reads it to refresh avatars and writes it on upload. Add it.
18. **Manage Users live roster scope.** The live query is `users where organizationId == org`. Members linked only through memberships, `userEmails` or staff links aren't live on iOS; they refresh on the next full load. Say whether a membership-scoped query (or a members collection listener) is the rule.
19. **Id letter case.** iOS builds booking pair keys and timesheet entry ids from `UUID.uuidString` (upper case). Web documents may use lower case. Clash `resolvedKeys` can miss a web-written key; `acceptedBookingClashes` is matched case-insensitively. Add a canonical id normalisation (for example `normalizeDocumentId`) used inside `clashPairKey`, `clashResolutionKey` and the timesheet entry-review map keys.

## C. Web behaviour that differs from the rulebook (fix on web)

20. **Timesheet draft saves.** Web `saveTimesheetDraft` does a full `setDoc(merge)`, and the owner resends the manager sign-off and export fields. iOS now reloads first, sends only changed owner-writable fields, and never sends sign-off or export fields. `timesheetOwnerWriteFields` (`timesheetEntryReviews.ts` ~270) should strip sign-off and export fields itself, not rely on them being resent unchanged.
21. **Leave saves.** Web `saveBooking` for `holidayBookings` still uses a full merge-set for edits. Make it partial.
22. **PAYE lines on the live invoice.** Web's live invoice path (no `weeklyReportOverride`) still includes PAYE 0 lines. The signed-sheet path and iOS leave them out. Pick one and put it in §8.
23. **Rate history day.** Web's history writer uses `londonMidnight(effectiveAt)`. §1 says the organisation zone. iOS writes org-zone midnight.
24. **Legacy literal currency field.** Older iOS builds wrote a top-level literal field named `settings.currencyCode`. `resolveOrganizationCurrency` reads it last, so it's harmless. Optionally delete it in a one-off clean-up (`FieldPath(['settings.currencyCode'])`).

## D. iOS follow-ups (for the record; iOS will do these after the next sync)

- My Schedule total card and Daily Overview per-person pills: switch to `workedHoursSplit` as web does. Daily Overview day totals already use it.
- Gate employment-type changes on `canChangePersonPay`.
- `ProjectStore` / `OperativeStore` still resave every project and client on reconnect with full writes.
- Home's pending-leave badge does not use the item 3 queue yet.

---

## Done when

- [ ] Items 1–4 are written into `docs/RULEBOOK.md`, with exports and rules where named.
- [ ] Items 5–19 each have a decision, an export or rule change, and a `canonical.test.ts` case where behaviour changed.
- [ ] Items 20–24 are fixed on web or answered.
- [ ] The rulebook version is bumped, re-packed, and `docs/ios-handoff/LATEST.md` written, so the iOS agent can run `scripts/sync-rulebook-from-web.sh` and remove each `RULEBOOK-GAP` stopgap.
