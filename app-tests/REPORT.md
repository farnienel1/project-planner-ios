# Security rules report

Tested rules file: `Project Planner/firestore.rules`.

That is the file `Project Planner/firebase.json` deploys (`firestore.rules` next to that config). `website/firestore.rules` was not loaded. It is a separate copy and is missing later matches (`materialSendRecords`, `wholesalers`, `platformConfig`, and others).

These results come from `@firebase/rules-unit-testing` against the Firestore emulator. They are not UI tests.

Result: FAIL.

Probes that correctly denied access: 592. Probes that correctly allowed access: 367. Forbidden actions that were allowed: 1231, in 18 rule groups.

## CRITICAL

### 1. Operatives, QS, and sub contractor accounts can change staff-only organisation data

- Rule: `per-collection allow create/update that calls canAccessOrganization or allow write` in `Project Planner/firestore.rules`
- Lines: 429–559
- Also: See each example path. settings is lines 484–487. qualifications and skills use allow write at 473–481, which includes delete.
- Suggested fix: After canAccessOrganization is tenant-scoped, require an org admin or manager (materialManagerLikeUser / isOrganizationAdmin, same organisation) for creates and updates on projects, smallWorks, clients, operatives, bookings, qualifications, skills, settings other than the caller's own timesheet, managers, notifications, materialCatalogue, wholesalers, managerSiteBookings, subcontractors, subcontractorBookings, and staff edits of someone else's materials. Operatives with siteAudit may write siteAudits. Operatives may write their own operativeProfiles/{uid} and their own holidayBookings. They must not write the managers roster, org settings, or catalogue/wholesaler records.

Examples the emulator allowed:

- operative create `organizations/org-a/projects/create-operative`
- operative update `organizations/org-a/projects/project-1`
- qs create `organizations/org-a/projects/create-qs`
- qs update `organizations/org-a/projects/project-1`
- subcontractor create `organizations/org-a/projects/create-subcontractor`
- subcontractor update `organizations/org-a/projects/project-1`
- operative create `organizations/org-a/smallWorks/create-operative`
- operative update `organizations/org-a/smallWorks/sw-1`
- qs create `organizations/org-a/smallWorks/create-qs`
- qs update `organizations/org-a/smallWorks/sw-1`
- subcontractor create `organizations/org-a/smallWorks/create-subcontractor`
- subcontractor update `organizations/org-a/smallWorks/sw-1`
- 151 more staff-write allows were recorded in this run.

### 2. Any signed-in user can read and write another organisation's data

- Rule: `function canAccessOrganization` in `Project Planner/firestore.rules`
- Lines: 90–96
- Also: function isAdminOrSuperAdmin lines 212–216. Matches that call canAccessOrganization include projects (429–433), smallWorks (442–445), clients (455–458), operatives (461–464), bookings (467–470), qualifications (473–476), skills (478–481), settings (484–487), tasks (489–492), managers (495–498), notifications (501–505), materials read (507–508), managerSiteBookings (534–538), subcontractors (540–543), subcontractorBookings (546–549), operativeProfiles (557–559), siteAudits (561–565), and the catch-all read at 592–594 (operativeDayRateHistory and any other subcollection).
- Suggested fix: Delete `|| organizationExists(organizationId)` from canAccessOrganization. Do not treat isAdminOrSuperAdmin() as membership: that helper is not scoped to the path's organisation, so an admin of company B matches it for company A. canAccessOrganization should be belongsToOrganization(organizationId) only. Then add role checks on each match so operativeMode, role == 'operative', role == 'qs', and role == 'subcontractor' cannot write staff-only collections (projects, clients, bookings, settings, wholesalers, the managers roster, and the rest of the staff write list below).

Examples the emulator allowed:

- otherOrg get `organizations/org-a/projects/project-1`
- otherOrg list `organizations/org-a/projects`
- otherOrg create `organizations/org-a/projects/create-otherOrg`
- otherOrg update `organizations/org-a/projects/project-1`
- otherOrgAdmin get `organizations/org-a/projects/project-1`
- otherOrgAdmin list `organizations/org-a/projects`
- otherOrgAdmin create `organizations/org-a/projects/create-otherOrgAdmin`
- otherOrgAdmin update `organizations/org-a/projects/project-1`
- otherOrg get `organizations/org-a/smallWorks/sw-1`
- otherOrg list `organizations/org-a/smallWorks`
- otherOrg create `organizations/org-a/smallWorks/create-otherOrg`
- otherOrg update `organizations/org-a/smallWorks/sw-1`
- 614 more tenant-hole allows were recorded in this run.

### 3. Non-admins can delete organisation records

- Rule: `allow write / allow delete on the match in the example path` in `Project Planner/firestore.rules`
- Lines: 473–481 and 557–559
- Also: qualifications and skills use allow write, so delete is included. operativeProfiles allows delete for canAccessOrganization.
- Suggested fix: Split allow write into allow create, update and allow delete. Delete of qualifications, skills, and operativeProfiles should require isOrganizationAdmin(organizationId). Do not grant delete through canAccessOrganization.

Examples the emulator allowed:

- manager delete `organizations/org-a/qualifications/delete-manager`
- operative delete `organizations/org-a/qualifications/delete-operative`
- qs delete `organizations/org-a/qualifications/delete-qs`
- subcontractor delete `organizations/org-a/qualifications/delete-subcontractor`
- manager delete `organizations/org-a/skills/delete-manager`
- operative delete `organizations/org-a/skills/delete-operative`
- qs delete `organizations/org-a/skills/delete-qs`
- subcontractor delete `organizations/org-a/skills/delete-subcontractor`
- operative delete `organizations/org-a/managerSiteBookings/delete-operative`
- qs delete `organizations/org-a/managerSiteBookings/delete-qs`
- subcontractor delete `organizations/org-a/managerSiteBookings/delete-subcontractor`
- operative delete `organizations/org-a/subcontractorBookings/delete-operative`
- 31 more admin-delete allows were recorded in this run.

### 4. Operatives can change organisation settings, including payroll settings

- Rule: `match /settings/{settingId}` in `Project Planner/firestore.rules`
- Lines: 484–487
- Also: allow write is canAccessOrganization, so every member (and, until tenant-hole is fixed, every signed-in user) can overwrite jobTypes, payroll, and variationTrades.
- Suggested fix: Keep read of non-financial settings such as jobTypes for organisation members. allow write only for isOrganizationAdmin or a manager who is not operativeMode, scoped with belongsToOrganization. Put payrollTimePolicy and invoicing amounts on settings/payroll (or a private doc) and allow read of that document only for admins and managers. The organisation root document currently also stores payrollTimePolicy, and every member can read that root.

Examples the emulator allowed:

- manager delete `organizations/org-a/settings/delete-manager`
- operative list `organizations/org-a/settings`
- operative create `organizations/org-a/settings/create-operative`
- operative update `organizations/org-a/settings/jobTypes`
- operative delete `organizations/org-a/settings/delete-operative`
- qs list `organizations/org-a/settings`
- qs create `organizations/org-a/settings/create-qs`
- qs update `organizations/org-a/settings/jobTypes`
- qs delete `organizations/org-a/settings/delete-qs`
- subcontractor list `organizations/org-a/settings`
- subcontractor create `organizations/org-a/settings/create-subcontractor`
- subcontractor update `organizations/org-a/settings/jobTypes`
- 14 more settings allows were recorded in this run.

### 5. Operatives, QS, and sub contractor accounts can read staff-only or financial records

- Rule: `allow read: if canAccessOrganization(organizationId), and the catch-all read` in `Project Planner/firestore.rules`
- Lines: 484–487, 495–498, 507–508, 516–518, 521–524, 529–530, 592–594
- Also: operativeDayRateHistory has no match of its own, so the catch-all at 592–594 allows the read. materialSendRecords (521–524) is already limited to admins and managers; keep that.
- Suggested fix: Add match /operativeDayRateHistory/{id} with read, create, update, delete only for isOrganizationAdmin or isOrganizationMaterialManager of that same organisation. Restrict settings/payroll and other people's timesheet_* documents the same way. Restrict managers, materialCatalogue, and wholesalers reads to admin and manager. Do not leave financial documents on the catch-all.

Examples the emulator allowed:

- operative get `organizations/org-a/managers/doc-1`
- operative list `organizations/org-a/managers`
- qs get `organizations/org-a/managers/doc-1`
- qs list `organizations/org-a/managers`
- subcontractor get `organizations/org-a/managers/doc-1`
- subcontractor list `organizations/org-a/managers`
- operative get `organizations/org-a/materialCatalogue/doc-1`
- operative list `organizations/org-a/materialCatalogue`
- qs get `organizations/org-a/materialCatalogue/doc-1`
- qs list `organizations/org-a/materialCatalogue`
- subcontractor get `organizations/org-a/materialCatalogue/doc-1`
- subcontractor list `organizations/org-a/materialCatalogue`
- 108 more staff-read allows were recorded in this run.

### 6. Operatives can create warning notifications

- Rule: `match /notifications/{notificationId}` in `Project Planner/firestore.rules`
- Lines: 501–505
- Also: allow create, update is canAccessOrganization. Issuing a warning is a notification whose type is warning_removed or booking_clash. The product does not let operatives issue warnings.
- Suggested fix: Allow create and update for organisation members only when request.resource.data.type is not a warning type (warning_removed, booking_clash, and the other warning notification types). Warning types require an org admin or manager in that organisation. Combine this with the tenant fix so another organisation's user cannot create them either.

Examples the emulator allowed:

- operative create `organizations/org-a/notifications/create-operative`
- operative update `organizations/org-a/notifications/doc-1`
- qs create `organizations/org-a/notifications/create-qs`
- qs update `organizations/org-a/notifications/doc-1`
- subcontractor create `organizations/org-a/notifications/create-subcontractor`
- subcontractor update `organizations/org-a/notifications/doc-1`
- otherOrg get `organizations/org-b/notifications/doc-1`
- otherOrg list `organizations/org-b/notifications`
- otherOrg create `organizations/org-b/notifications/create-otherOrg`
- otherOrg update `organizations/org-b/notifications/doc-1`
- otherOrgAdmin get `organizations/org-b/notifications/doc-1`
- otherOrgAdmin list `organizations/org-b/notifications`
- 2 more notifications allows were recorded in this run.

### 7. Any signed-in user can read and write every organisation's holiday bookings

- Rule: `match /holidayBookings/{bookingId}` in `Project Planner/firestore.rules`
- Lines: 552–555
- Also: The comment marks this as temporary.
- Suggested fix: Replace `if request.auth != null` with belongsToOrganization(organizationId). A member may create and update their own booking (userId == request.auth.uid). Approving or deleting someone else's booking should require an org admin or a manager with operatives permission in that same organisation.

Examples the emulator allowed:

- otherOrg get `organizations/org-a/holidayBookings/doc-1`
- otherOrg list `organizations/org-a/holidayBookings`
- otherOrg create `organizations/org-a/holidayBookings/create-otherOrg`
- otherOrg update `organizations/org-a/holidayBookings/doc-1`
- otherOrg delete `organizations/org-a/holidayBookings/delete-otherOrg`
- otherOrgAdmin get `organizations/org-a/holidayBookings/doc-1`
- otherOrgAdmin list `organizations/org-a/holidayBookings`
- otherOrgAdmin create `organizations/org-a/holidayBookings/create-otherOrgAdmin`
- otherOrgAdmin update `organizations/org-a/holidayBookings/doc-1`
- otherOrgAdmin delete `organizations/org-a/holidayBookings/delete-otherOrgAdmin`
- admin get `organizations/org-b/holidayBookings/doc-1`
- admin list `organizations/org-b/holidayBookings`
- 33 more holidayBookings allows were recorded in this run.

### 8. Any signed-in user can read, write, and change variation status, including across organisations

- Rule: `match /variations/{variationId} and match /variationTrackers/{parentId}` in `Project Planner/firestore.rules`
- Lines: 582–588
- Also: The comment above the match says the rule is auth-open like holidayBookings. The iOS client only lets admins, and managers assigned to that job, see or edit variations (WorkAccess.canAccessVariations). There is no QS role. Operatives never get the feature.
- Suggested fix: Replace `if request.auth != null` with belongsToOrganization(organizationId). Allow update of status only when isOrganizationAdmin(organizationId) is true, or when the caller is a manager in this organisation and request.auth.uid is in the parent project or small-work document's managerUserIds. Deny role == 'operative', operativeMode, role == 'qs', and role == 'subcontractor'. Apply the same tenant check to variationTrackers. A manager who is not on that job's managerUserIds must not change status.

Examples the emulator allowed:

- manager delete `organizations/org-a/variations/delete-manager`
- operative get `organizations/org-a/variations/doc-1`
- operative list `organizations/org-a/variations`
- operative create `organizations/org-a/variations/create-operative`
- operative update `organizations/org-a/variations/doc-1`
- operative delete `organizations/org-a/variations/delete-operative`
- qs get `organizations/org-a/variations/doc-1`
- qs list `organizations/org-a/variations`
- qs create `organizations/org-a/variations/create-qs`
- qs update `organizations/org-a/variations/doc-1`
- qs delete `organizations/org-a/variations/delete-qs`
- subcontractor get `organizations/org-a/variations/doc-1`
- 116 more variations allows were recorded in this run.

### 9. Operatives can read and edit other people's timesheets

- Rule: `match /settings/{settingId}` in `Project Planner/firestore.rules`
- Lines: 484–487
- Also: Timesheets are settings documents whose id is timesheet_{userId}_{weekStamp} (FirebaseBackend.timesheetStateDocumentRef). The same allow read/write covers every settings id, so ownership is never checked.
- Suggested fix: When the document id matches timesheet_ or resource.data.userId is a string, allow read and write only if request.auth.uid == that userId, or the caller is an org admin, or a manager in the same organisation. Deny everyone else, including other operatives, QS, and sub contractor accounts. Do not use a blanket allow write on settings/{settingId}.

Examples the emulator allowed:

- operative get `organizations/org-a/settings/timesheet_user-manager_1700000000`
- qs get `organizations/org-a/settings/timesheet_user-manager_1700000000`
- subcontractor get `organizations/org-a/settings/timesheet_user-manager_1700000000`
- otherOrg get `organizations/org-a/settings/timesheet_user-manager_1700000000`
- otherOrgAdmin get `organizations/org-a/settings/timesheet_user-manager_1700000000`
- operative update `organizations/org-a/settings/timesheet_user-manager_1700000000`
- qs update `organizations/org-a/settings/timesheet_user-manager_1700000000`
- subcontractor update `organizations/org-a/settings/timesheet_user-manager_1700000000`
- otherOrg update `organizations/org-a/settings/timesheet_user-manager_1700000000`
- otherOrgAdmin update `organizations/org-a/settings/timesheet_user-manager_1700000000`

### 10. Any organisation member can rewrite company settings, including warning detection and payroll

- Rule: `match /organizations/{organizationId} allow update` in `Project Planner/firestore.rules`
- Lines: 420–425
- Also: The third clause allows the update when the caller is still in request.resource.data.members and the organisation exists. It does not limit which fields change. warningDetection and payrollTimePolicy live on this document.
- Suggested fix: Delete the members-map branch. Allow update only for isOrganizationAdmin(organizationId) (same organisation, not a global admin flag). Operatives, QS, sub contractor accounts, and managers must not be able to write warningDetection or payrollTimePolicy.

Examples the emulator allowed:

- operative update `organizations/org-a`
- operative update-payroll `organizations/org-a`
- qs update `organizations/org-a`
- qs update-payroll `organizations/org-a`
- subcontractor update `organizations/org-a`
- subcontractor update-payroll `organizations/org-a`
- manager update `organizations/org-a`
- manager update-payroll `organizations/org-a`

### 11. An admin of one organisation is treated as an admin of every organisation

- Rule: `function isAdminOrSuperAdmin, used by match /organizations/{organizationId} allow read` in `Project Planner/firestore.rules`
- Lines: 212–216 and 408–413
- Also: isAdminOrSuperAdmin() does not compare organizationId. A company admin of org B therefore passes the org A read rule.
- Suggested fix: On organisation documents, drop the bare isAdminOrSuperAdmin() clause. Membership, userOrgIdMatchesPath(organizationId), or creatorUserId is enough. Anywhere else that helper gates another tenant's data, require userOrgIdMatchesPath for that path as well. Reserve a true platform super-admin (isSuperAdmin == true) for platformConfig only.

Examples the emulator allowed:

- otherOrgAdmin update `organizations/org-a`
- otherOrgAdmin update-payroll `organizations/org-a`
- otherOrgAdmin get `organizations/org-a`

### 12. Any signed-in user can read every user document, including another organisation's payroll fields

- Rule: `match /users/{userId}` in `Project Planner/firestore.rules`
- Lines: 288–290
- Also: allow read and allow list are `if request.auth != null`. User documents store dayRate, hourlyRate, vatNumber, and utrNumber.
- Suggested fix: Allow get of users/{uid} when request.auth.uid == uid, or when the caller is an admin or manager whose users/{uid}.organizationId matches the target document's organizationId. Deny list of the whole users collection. A query filtered to the caller's own organisation can stay allowed for admins and managers. Move dayRate, hourlyRate, vatNumber, and utrNumber to users/{uid}/payroll/current and allow that subdocument only to the user, their manager, and an org admin. Until that split exists, operatives must not be able to get a colleague's user document.

Examples the emulator allowed:

- otherOrg get `users/user-admin`
- otherOrgAdmin get `users/user-admin`
- operative get `users/user-admin`
- qs get `users/user-admin`
- subcontractor get `users/user-admin`
- admin get `users/user-other`
- operative list `users`
- otherOrg list `users`
- otherOrgAdmin list `users`
- qs list `users`
- subcontractor list `users`
- otherOrg query `users where organizationId == org-a`

### 13. A user can grant themselves admin, and any signed-in user can patch another person's day rate

- Rule: `match /users/{userId} allow update, plus function canPatchOperativeProfileMetadataOnly` in `Project Planner/firestore.rules`
- Lines: 255–265 and 323–342
- Also: Self-update is allowed with no field list, so role, adminAccess, isSuperAdmin, and organizationId can be changed. canPatchOperativeProfileMetadataOnly is true for any signed-in user whose changed keys are only day rate and employment metadata.
- Suggested fix: Remove canPatchOperativeProfileMetadataOnly from the update allow. Keep canManagerUpdateOperativeProfile for a manager in the same organisation. When request.auth.uid == userId, changedKeys().hasOnly a profile allow-list that does not include role, adminAccess, isSuperAdmin, manager, operativeMode, organizationId, dayRate, hourlyRate, vatNumber, or utrNumber.

Examples the emulator allowed:

- operative update-dayRate `users/user-manager`
- qs update-dayRate `users/user-manager`
- subcontractor update-dayRate `users/user-manager`
- otherOrg update-dayRate `users/user-manager`
- otherOrgAdmin update-dayRate `users/user-manager`
- operative self-escalate `users/user-operative`
- qs self-escalate `users/user-qs`
- subcontractor self-escalate `users/user-sub`

### 14. Signed-out users can read invitations, and any signed-in user can write them

- Rule: `match /invitations/{invitationId}` in `Project Planner/firestore.rules`
- Lines: 275–279
- Also: allow read: if true covers get and list, so the whole invitation collection (emails, organisation ids, permissions) is public. allow write: if request.auth != null lets an operative create invites.
- Suggested fix: Remove `allow read: if true` and the open write. Allow get and write only for an admin of the invitation's organizationId. Redeem a signup invitation through a Cloud Function so an unauthenticated client never lists this collection.

Examples the emulator allowed:

- signedOut get `invitations/invite-1`
- signedOut list `invitations`
- otherOrg get `invitations/invite-1`
- otherOrg list `invitations`
- otherOrgAdmin get `invitations/invite-1`
- otherOrgAdmin list `invitations`
- operative get `invitations/invite-1`
- operative list `invitations`
- qs get `invitations/invite-1`
- qs list `invitations`
- subcontractor get `invitations/invite-1`
- subcontractor list `invitations`
- 4 more invitations allows were recorded in this run.

### 15. Any signed-in user can read or claim email rows in another organisation

- Rule: `match /userEmails/{emailKey}` in `Project Planner/firestore.rules`
- Lines: 396–402
- Also: allow read is any authenticated user. create/update allows any caller who sets userId to their own uid, in any organisation path.
- Suggested fix: allow read only for belongsToOrganization(organizationId). allow create, update only when belongsToOrganization(organizationId) and (isOrganizationAdmin(organizationId) or request.resource.data.userId == request.auth.uid). Keep delete on isOrganizationAdmin.

Examples the emulator allowed:

- otherOrg get `organizations/org-a/userEmails/admin@org-a.test`
- otherOrg create `organizations/org-a/userEmails/intruder@orgb.test`
- otherOrgAdmin get `organizations/org-a/userEmails/admin@org-a.test`
- otherOrgAdmin create `organizations/org-a/userEmails/intruder@orgb.test`

### 16. A global admin flag can read and write org memberships in another organisation

- Rule: `match /users/{userId}/orgMemberships/{orgId}` in `Project Planner/firestore.rules`
- Lines: 377–389
- Also: isAdminOrSuperAdmin() is not compared to orgId.
- Suggested fix: Allow read, write, and delete when request.auth.uid == userId, or when the caller is an admin whose users document organizationId matches both the target user and orgId. Do not use a global isAdminOrSuperAdmin() check here.

Examples the emulator allowed:

- otherOrgAdmin get `users/user-manager/orgMemberships/org-a`

### 17. Any company admin can write platform-wide config

- Rule: `match /platformConfig/{docId}` in `Project Planner/firestore.rules`
- Lines: 597–600
- Also: allow write: if isAdminOrSuperAdmin() is true for every user with adminAccess or role == 'admin', in every organisation.
- Suggested fix: allow read: if request.auth != null can stay for the shared toolbox library. allow write only when users/{uid}.isSuperAdmin == true. A company admin must not write platformConfig.

Examples the emulator allowed:

- admin update `platformConfig/toolboxTalkLibrary`
- otherOrgAdmin update `platformConfig/toolboxTalkLibrary`

### 18. Any signed-in user can list every organisation

- Rule: `match /organizations/{organizationId} allow list` in `Project Planner/firestore.rules`
- Lines: 415
- Also: Get of a single organisation document is tighter than list. list returns every organisation document to any authenticated user.
- Suggested fix: Remove `allow list: if request.auth != null`. Clients should get the organisation by id from users/{uid}.organizationId. If a list is required, it has to be constrained to organisations whose members map contains request.auth.uid (a query the rules can prove).

Examples the emulator allowed:

- otherOrg list `organizations`
- otherOrgAdmin list `organizations`

## Not CRITICAL

These probes expected an allow and the rules denied it. That is tighter than the product client, not an extra grant. They do not by themselves fail the security assertion.

- manager update `organizations/org-a/materialSendRecords/doc-1` was denied
- admin create `organizations/org-a/operativeDayRateHistory/create-admin` was denied
- admin update `organizations/org-a/operativeDayRateHistory/doc-1` was denied
- admin delete `organizations/org-a/operativeDayRateHistory/delete-admin` was denied
- manager create `organizations/org-a/operativeDayRateHistory/create-manager` was denied
- manager update `organizations/org-a/operativeDayRateHistory/doc-1` was denied

## App races seen on the three phones (5 Oct 2026)

These are product timing issues, not security-rule failures. The rules result above is unchanged: 1231 forbidden actions were still allowed.

- Home can show 0 active projects while organisation data is still loading, then settle on the date-active count. After the refresh trigger includes “org data ready”, admin, operative, and manager Home each settled on 1 active project (C984, 10 Sep–10 Oct 2026). A refresh that returns early during bootstrap now restarts when bootstrap finishes.
- Up next kept Monday 5 Oct and Tuesday 6 Oct on the admin and operative Home after 16:00, so a booking is not dropped once its start time has passed while the day is still today.
- Book labour stores the organisation user-document id. My Schedule now matches the signed-in Auth uid and every users-document id for the same email. Thursday 22 Oct 2026 C984 07:30–16:00 showed on Manager Tester’s My Schedule and, after the manager booked Test Admin, on Test Admin’s My Schedule and on both Daily Overviews.
- Snapshot tests `testAppearanceSettings`, `testChooseMode`, `testGeneralSettings`, `testMyScheduleOptions`, and `testVariationTracker` crash the test host with `malloc: pointer being freed was not allocated` and the runner restarts. The other snapshot screens in that run passed. The 33 logic tests passed with 0 failures. This crash was not changed in the app.
- Smoke UI tests on iPhone 16e: 30 ran, 5 passed (admin, manager, and operative reach Home; empty sign-in stays disabled; home greeting and date). 25 failed because the tests look for identifiers such as `notifications.screen`, `projects.screen`, `leave.screen`, and `mainMenu.screen`, and the app uses the names from the identifier sweep (`home.notifications`, `home.row.*`, `mainMenu.row.*`). Wrong-password also failed because `TEST_RUNNER_ADMIN_EMAIL` was not passed to xcodebuild. Sign-out did not return to `signIn.email`. These are harness gaps, not a change to booking or leave behaviour.
