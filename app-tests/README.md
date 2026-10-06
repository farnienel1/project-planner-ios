# App security-rules tests

These tests talk to the Firestore emulator. They check `firestore.rules` and `storage.rules` directly. They do not launch the iOS app or an iOS simulator, and they do not use the live Firebase project.

## Rules file under test

`Project Planner/firestore.rules`

That is the file the iOS app ships. `Project Planner/firebase.json` sets `firestore.rules` to `firestore.rules` beside that config, which resolves to `Project Planner/firestore.rules`.

`website/firestore.rules` is a separate copy. It is not referenced by `firebase.json`, and these tests do not load it. It is behind the iOS file: it has no `canReadMaterialSendHistory` helper and no matches for `materialSendRecords`, `wholesalers`, `acceptedBookingClashes`, `dashboardLayouts`, or `platformConfig`.

There is no `storage.rules` anywhere in the repo. `Project Planner/firebase.json` has no `storage` block. The storage test records that as a failure. The iOS app still uploads task files, health-and-safety files, site-audit photos, profile photos, the company logo, qualification certificates, variation evidence, and timesheet PDFs.

## Run

From the repo root:

```sh
npm install
npm run test:rules
```

Or:

```sh
scripts/test-rules.sh
```

`scripts/test-rules.sh` installs npm dependencies if they are missing, finds Java if Homebrew installed it as a keg-only JDK, and then runs `npm run test:rules`.

`npm run test:rules` starts the Firestore emulator on `127.0.0.1:8188` with `app-tests/firebase.json` and runs `app-tests/rules/*.test.mjs`. The emulator project id is `demo-project-planner`. The test process loads `Project Planner/firestore.rules` into that emulator itself.

You need Node.js 20+ and a Java runtime the Firestore emulator can start (Java 21 is the current firebase-tools requirement). On a Mac:

```sh
brew install openjdk@21
```

The first run downloads the Firestore emulator. That needs network access. Later runs reuse the cached emulator.

## What is asserted

Each signed-in role is a Firestore user document plus a membership on an organisation:

| Actor | How the test signs them in |
| --- | --- |
| admin | `role: admin`, `adminAccess: true`, organisation A |
| manager | `role: manager`, `manager` and `operatives` set, organisation A |
| operative | `role: operative`, `operativeMode: true`, organisation A |
| QS | `role: qs` with no admin, manager, or operative flags. The product has no QS role. Variation status is for admins and managers assigned to that job. |
| sub contractor | `role: subcontractor` with no admin or manager flags. Sub contractor firms live in `subcontractors`; this actor is a signed-in user, not a firm row. |
| other organisation | operative of organisation B, and separately an admin of organisation B |
| signed-out | no auth token |

For every organisation collection the iOS app reads or writes, each actor attempts get, list, create, update, and delete. The suite also checks user documents, org memberships, invitations, platform config, timesheet settings documents, payroll settings, variation status, warning notifications, and day-rate edits.

A failure means the rules allowed an action the test treats as forbidden. The assertion is not relaxed to match the current rules. `app-tests/REPORT.md` is rewritten at the end of the Firestore run. `CRITICAL` entries name the rule path and a suggested fix. Do not edit `Project Planner/firestore.rules` just to go green without reading that report. The rules file is the thing under test.

Collections covered: `invitations`, `users`, `users/{id}/orgMemberships`, `organizations`, `userEmails`, `projects`, `projects/{id}/healthSafety`, `smallWorks`, `smallWorks/{id}/healthSafety`, `clients`, `operatives`, `bookings`, `qualifications`, `skills`, `settings` (including job types, payroll, and `timesheet_{userId}_{week}`), `tasks`, `managers`, `notifications`, `materials`, `materialCatalogue`, `materialSendRecords`, `wholesalers`, `managerSiteBookings`, `subcontractors`, `subcontractorBookings`, `holidayBookings`, `operativeProfiles`, `siteAudits`, `variations`, `variationTrackers`, `operativeDayRateHistory`, and `platformConfig`.

## Reading a red run

`npm run test:rules` exits non-zero when a forbidden action is allowed, when a sanity check cannot read the admin's own project (rules did not load), or when `storage.rules` is missing. Open `app-tests/REPORT.md` for the grouped gaps. Actions the rules correctly denied are counted in that file and do not fail the run.

## Snapshot tests

`app-tests/APP_MAP.md` was not in the repo when these snapshots were added. Coverage is every screen that already renders from fixed local data, with no network call. `app-tests/VISUAL_ISSUES.md` was not present, so no open-issue markers are attached to the tests.

Simulator: iPhone 16e, iOS 26.2 (UDID `9250FFF9-6782-4AF9-96C3-8E2C04D880A4`).
Snapshot layout: `ViewImageConfig.iPhone13` portrait, 390×844 pt @3x, the same point size as iPhone 16e.
Each covered screen is recorded in light, dark, and accessibility-large.

If a snapshot fails after an intended UI change, review the diff image in the test results, then re-record that test only.

### Covered

These screens already accept fixed data, or they are static forms that do not load on appear:

- Sign in
- Reset password (email is a binding; the sample address is `planner.snapshot@example.com`)
- Change password
- Help & support
- Help topic: Projects
- Privacy & terms
- Choose mode (theme written through the existing settings store)
- Appearance
- General settings
- My Schedule options (office, site survey, and a custom “Plant” item)
- Job types (`CAT A`, `CAT B`, `Maintenance`)
- Clients (two fixed client cards)
- New client
- New operative
- New manager
- Add job type
- Add user (administrator, first step)
- Variation tracker, read-only (two fixed variations; the screen does not start Firebase listeners)

### Skipped

- Deadlines (`DLDeadlinesScreen` and the deadline sheets). `DLStore.sample()` dates every row from today, and the screen does not take a fixed calendar, so the image would change every day.
- Booking confirmation. It animates on appear and dismisses itself, so the frame is not stable.
- Launch splash. The progress spinner is not a fixed frame.
- Midnight reference previews in `PPReferencePreviews.swift`. They are private debug canvases, not the real screens.

### Covered by the screenshot tour only

These screens load or listen over the network when they appear, and they do not already accept a fixed in-memory sample:

- Home
- Projects and project detail
- Create project and create small works (they resolve an office coordinate on appear)
- Small works
- Tasks
- Schedule, book labour, and My Schedule
- Daily overview
- Annual leave and holiday report
- Warnings
- Operatives and managers
- Notifications
- Site audit
- Timesheets and invoicing
- Settings, profile, and manage users
- Qualifications
- Variations list
- Wholesalers and the material catalogue
- Organisation settings
- Policy acceptance
- Account deactivated and switch organisation
- Site map
