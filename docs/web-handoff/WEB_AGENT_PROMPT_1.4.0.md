# Web agent prompt: rulebook 1.4.0 (bank-holiday region, company activity notices, push test)

Paste this whole file into the agent working in **project-planner-web**.

## Where things stand
- **Rulebook 1.3.0** (line managers, notification recipients) is merged in both apps:
  - web #208 into `main-kr70k9`;
  - iOS #142 into `main` (iOS runs pack `644bb679…`).
- **Your 1.3.0 review items** (from `docs/web-handoff/WEB_AGENT_PROMPT_1.3.0.md` in the iOS repo) still apply:
  - run `npm ci && npx tsc --noEmit && npm test` and `npm run test:rules`;
  - check the Netlify preview;
  - confirm admins see the timesheets of legacy operatives and managers who have no line manager.

The product owner has decided three new rules. They are new behaviour, so this is rulebook **1.4.0**:
1. Start in `lib/canonical`, with tests in `canonical.test.ts` and `parity-fixture.json`.
2. Update `docs/RULEBOOK.md`: `Version: 1.4.0` and a changelog entry.
3. Run `npm run build:canonical` and `npm run rulebook:handoff`.
4. Implement the web screens.
5. Give the product owner `docs/ios-handoff/LATEST.md` for the iOS agent.

Name every function you add. No second copy in a page or store.

## 1. Changing the country asks for the bank-holiday region (§4.1, §4.4)

**Owner's decision:** when Company Details changes the company's country, both apps prompt for that country's bank-holiday region, and the save is not finished until one is chosen.

Today each app keeps its own region list: web `lib/settings/bankHolidayRegions.ts`, iOS `Core/BankHolidayRegionDirectory.swift`. That is a second copy of a shared rule.

**`lib/canonical`:**
- Move the region list here as `BANK_HOLIDAY_REGIONS`: `{ id, title, countryCode, subdivisionCodes? }`. Keep the existing ids, such as `GB-ENG-WLS`, `GB-SCT`, `GB-NIR`, `GB`, `IE`, `US`.
- Add:
  - `bankHolidayRegionsForCountry(countryCode)`;
  - `defaultBankHolidayRegionForCountry(countryCode)`. GB gives `GB-ENG-WLS` (keep `DEFAULT_BANK_HOLIDAY_REGION_ID`). A country with a single region gives that region. A country with no listed regions gives `null`.
- Add `companyDetailsRegionPrompt(previous, next)`. It returns `{ required: true, choices }` when the country changed and the saved `bankHolidayRegionId` does not belong to the new country; otherwise `{ required: false }`.
- `companyDetailsValidationError` refuses the save while that prompt is required and no region from `choices` is picked. Proposed message: "Choose the bank holidays for {country}."
- The time zone and default currency keep following the country automatically (`organizationTimeZone`, `defaultCurrencyForCountry`).
- `companyDetailsWriteFields` writes the new `countryCode` and `bankHolidayRegionId` in one partial update.
- **Annual leave:** existing leave records are never recounted or rewritten. Day counting (`leaveRecordDayKeys`, `annualLeaveBalance`) uses the region in effect when it runs. Say this in §4.4.

**Web:**
- `components/settings/panels/CompanyDetailsPanel.tsx`: when the country changes, show the region picker (only `bankHolidayRegionsForCountry`), pre-selected with `defaultBankHolidayRegionForCountry`, and block Save until a region is chosen.
- `AnnualLeaveDefaultsPanel.tsx`: its region picker offers only the company's country's regions.
- Delete `lib/settings/bankHolidayRegions.ts` once callers use the canonical list.

## 2. Company activity notices go to admins (§13)

**Owner's decision:** the notices written today with no `userId` go to the company's admins. That covers `operative_created`, `manager_created`, `client_created`, `project_created`, `small_works_created` and `warning_removed`. Today nobody ever sees them.

**`lib/canonical`:**
- Add `companyActivityRecipients(actor, roster)` in `notificationRecipients.ts`. It returns the active admins and super admins outside operative mode, minus the actor (`excludeActor`).
- One inbox row is written per admin: `userId` set, `actorUserId` set. A row without `userId` is never written again.
- Add a My notifications toggle, `companyActivity`. It is on by default and visible only to admins and super admins (`visibleNotificationPreferenceKeys`, `notificationPreferenceCopy`, `parseUserNotificationPreferences`). Map the six types to it (`notificationPreferenceKeyForType`).
- Proposed copy: "Company activity — people, clients, jobs added and warnings removed."
- The toggle stops the push only; the inbox row always shows (§13, unchanged).
- Push: keep the six types in `DEVICE_PUSH_NOTIFICATION_TYPES`.
- Update `NOTIFICATION_CATALOG` and the §13 table: recipients become `companyActivityRecipients`, and the "ownerless" status rows are removed.

**Web:**
- Write these six types through `companyActivityRecipients`: `lib/firebase/notifyInbox.ts` (client created), `components/warnings/WarningsScreen.tsx` (warning removed), and every other web writer of these types.
- Add the toggle to My notifications.

## 3. The push test stays and reaches its sender (§13)

**Owner's decision:** keep the Settings "send a test notification" so a person can check pushes work on their own phone.

**`lib/canonical`:**
- Add a new type, `push_test`, in `DEVICE_PUSH_NOTIFICATION_TYPES` and `NOTIFICATION_CATALOG`. Its recipient is the signed-in user (`pushTestRecipients(actor)` returns `[actor id]`). It is written by iOS, and by web too if web has a test button (web sends no browser or OS notifications, so the inbox row is its only effect there).
- No preference toggle can turn it off.
- Add `notificationPushesToActor(type)`, which is true only for `push_test`.

**`functions/index.js`:**
- The actor guard ("never push a row whose `userId` is its `actorUserId`") skips types where `notificationPushesToActor` is true.
- Everything else stays as it is.

**iOS** (via the hand-off): the Settings diagnostic writes `push_test` instead of `task_created`.

## 4. Still open from 1.3.0 (web only)
- Web leave code still uses London day keys from `lib/ios-parity/londonTime` (`formatLeaveDays.ts`, `holidayApprovalUtils.ts`, `leaveRequestDecision.ts`). Move them to the organisation zone (§1). Leave notice dates already use it.
- Note in §13 that iOS forced sign-outs (expired session, trial blocked) don't yet remove the push token. That's an iOS follow-up.

## 5. Tests
- **`canonical.test.ts` / `parity-fixture.json`:**
  - region lists per country;
  - the prompt is required on a country change and not when the country stays the same;
  - GB/IE/US defaults;
  - validation refuses a missing region;
  - `companyActivityRecipients` is admins only, never the actor, inactive and operative-mode admins excluded;
  - the `companyActivity` toggle is visible to admins only;
  - `push_test` reaches the actor and `notificationPushesToActor` is false for every other type.
- **`tests/firestore.rules.test.ts`:** notifications rules are unchanged, so add a case only if you touch them.
- **Functions:** a unit test, if the repo has one, showing `push_test` pushes to the actor and `timesheet_pending_manager_signoff` still does not.

## 6. Deploy order
1. Merge 1.4.0 into `main-kr70k9`, and #204 into `main`.
2. The iOS agent syncs with `scripts/sync-rulebook-from-web.sh` and follows `docs/ios-handoff/LATEST.md`.
3. Ship the iOS build.
4. `firebase deploy --only firestore:rules,functions`. The function change for `push_test` must ship with this deploy.

## Done when
- [ ] `docs/RULEBOOK.md` is 1.4.0 with the three rules (§4.1, §4.4, §13) and a changelog entry; the pack is rebuilt and the hand-off written.
- [ ] Web Company Details and Annual Leave Defaults use the canonical region list and prompt; the local region list is gone.
- [ ] The six company activity types are written per admin and never without a `userId`; the admin toggle exists.
- [ ] `push_test` reaches its sender; every other type still never pushes to its actor.
- [ ] `tsc`, unit tests, canonical tests and rules tests pass; the Netlify preview has been checked.
- [ ] `docs/ios-handoff/LATEST.md` has been given to the product owner for iOS.
