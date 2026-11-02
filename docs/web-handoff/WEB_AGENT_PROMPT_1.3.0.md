# Web agent prompt: rulebook 1.3.0 (line managers and notifications)

Paste this whole file into the agent working in **project-planner-web**.

## What already happened (do not redo it)

Rulebook **1.3.0** was written and implemented in both apps from the iOS session, on the product owner's instructions:

- **Web PR #208** (`rulebook-1.3.0-line-managers-notifications` into `main-kr70k9`) carries:
  - `docs/RULEBOOK.md` 1.3.0 and `lib/canonical`, packed as `644bb679d3bcf5a9483a6a24f8272d9300806c4fa940a429315cbd3a14f277c1`;
  - `firestore.rules` and `functions/index.js`;
  - the web app call sites.
- **iOS PR #142** (`main-vr2rt0-uoqzwv` into `main`) mirrors that pack exactly and makes the same app changes.
- PR #205 (rulebook 1.2.0) is already merged into `main-kr70k9`.

**Your job is to review and verify #208**, then do the web follow-ups below. Do not rewrite these rules. If you disagree with one, raise it with the product owner, change `lib/canonical` first with a version bump and a hand-off, and never diverge in app code.

Until #208 merges, do **not**:
- regenerate the iOS prompt from an older rulebook;
- run `scripts/sync-rulebook-from-web.sh` against `main-kr70k9` from the iOS side.

`main-kr70k9` without #208 is rulebook 1.2.0, and iOS now runs 1.3.0.

## The owner's decisions (now in RULEBOOK §8, §9, §11, §13, §16)

1. **Line managers.** Every operative and every manager needs an active line manager, whatever the annual-leave self-book permission. Only admins and super admins outside operative mode may have none.
   - Functions: `lineManagerRequired`, `lineManagerRequiredError`.
   - Message: "Set a line manager — this person's timesheets and annual leave need approval."
   - Manage Users on both apps refuses the save. "No line manager" is offered only to admins.
   - `usersMissingLineManager` lists people saved before this rule, for admins to fix.
2. **Admin or super admin with no active line manager is self-approved.**
   - **Timesheets.** `timesheetSelfSigned`:
     - no "note to manager" field;
     - no "pending manager signature" state;
     - signing completes the sheet, so generate invoice turns green.
   - **Annual leave.** The button reads "Submit", not "Submit request" (`leaveSubmitLabel`), and the leave saves approved (`canSelfBookAnnualLeave(user, roster)`).
   - An admin who *has* a line manager goes through normal approval.
   - Timesheets and annual leave are the only two things that need a line manager.
3. **Strict deciders.** With no active line manager (legacy data only now), only admins decide leave and sign timesheets, never "any manager".
   - Functions: `leaveApproverIds`, `canDecideLeave`.
   - Rules: `hbCanDecide`; `hbCallerSelfBooks` uses `hasCurrentLineManager`.
   - **Behaviour change:** a legacy operative or manager with no line manager no longer self-approves their timesheet. It waits for an admin.
4. **Notifications: one recipient rule per type, never the person who caused it.** This is `lib/canonical/notificationRecipients.ts` (`excludeActor`, `personIdSet`) plus one function per notice type. `NOTIFICATION_CATALOG` is the §13 table.
   - Every inbox row carries `actorUserId`. Scheduled reminders leave it out.
   - The push function never pushes to the actor. The badge counts only the recipient's own unread rows.
   - Sign-out removes the device's push token. That is iOS-only today.

### Why (the reported bug)
A manager's own timesheet and leave-request notices arrived on their own phone. The causes:
- Timesheet recipients never excluded the submitter, or inactive managers.
- Leave approvers excluded only the requester's exact id, not their former invite ids or same-email accounts.
- The push function had no actor guard.
- iOS never removed a phone's push token on sign-out, so a shared test phone kept receiving the previous account's pushes.

## Notification table (what the apps now do)

| Notification | Action | Recipients (rulebook function) | Push |
|---|---|---|---|
| holiday_request_submitted | Leave request, or a cancellation request, by someone who can't self-book | Active line managers; admins if none; never the requester (`holidayRequestRecipients`) | yes |
| holiday_request_approved / _declined | Line manager or admin decides | The requester, never the decider (`holidayDecisionRecipients`) | yes |
| line_manager_peer_update | One line manager decides leave, or signs a timesheet | The person's other line managers (`lineManagerPeerRecipients`) | no |
| timesheet_pending_manager_signoff | Owner signs their timesheet | Active line managers; admins if none; nobody when self-signed (`timesheetSubmittedRecipients`) | yes |
| timesheet_signed_by_manager | Line manager signs | The owner (`timesheetSignedRecipients`) | yes |
| timesheet_submission_reminder | Schedule | Each person who submits timesheets (no actor) | yes |
| material_order_placed | Material line added | The job's managers, minus the adder (`materialOrderRecipients` + `excludeActor`) | yes |
| variation / variation_renumbered / variation_added | Variation created or renumbered | `receivesJobNotification` with the job's managers, minus the actor | yes |
| toolbox_talk_issued / hs_toolbox_reminder | Talk issued, or reminder | The chosen or unsigned people, minus the issuer (`toolboxTalkRecipients`) | yes |
| booking_created | People booked (iOS) | The booked people, minus the booker (`bookingCreatedRecipients`) | yes |
| deadline_assigned | Assignees added | The new assignees, minus the actor (`deadlineAssignedRecipients`) | yes |
| idea_status / idea_shipped / idea_comment / idea_merged | Feedback board | Voters and author, minus the actor (`ideaRecipients`) | no |
| task_created / task_completed | Task flows (iOS) | Assignees / creator, minus the actor | yes |

Ownerless rows (`*_created`, `warning_removed`) are written without a `userId`, so they are never listed or pushed. That is recorded in the catalog Status column.

## Review checklist for #208
1. Run `npm ci && npx tsc --noEmit && npm test` (tsc could not run in the iOS session). Then run `npm run test:rules`. It passed 84/84 there.
2. Click through the Netlify preview:
   - **Manage Users:** it refuses an operative or manager without a line manager, and offers "No line manager" to admins only.
   - **Admin with no line manager:** the timesheet has no note-to-manager field and goes green after signing; leave shows "Submit" and saves approved.
   - **Submitting a timesheet or leave:** notifies the line manager, not the submitter.
3. Confirm admins see the timesheets of legacy operatives and managers who have no line manager. Those sheets now wait for an admin.

## Web follow-ups (yours)
1. **Done in #208:** leave notice dates use the organisation zone (`annualLeaveDecisionDateText(booking, timeZone)`). Other web leave code still imports `lib/ios-parity/londonTime` (`formatLeaveDays.ts`, `holidayApprovalUtils.ts`, `leaveRequestDecision.ts`). Move those day keys to the organisation zone too (§1).
2. **Done in #208:** §13 lists `deadline_reminder` / `deadline_due` as scheduled notices without `actorUserId`.
3. **Ownerless rows decision.** They are written on both apps and never delivered. Either address them to admins with a recipient function, or stop writing them. Put the decision in §13.
4. **Settings push diagnostic.** The iOS diagnostic writes `task_created` to the signed-in user. Now that it carries `actorUserId`, it never pushes. The catalog says remove it; confirm.
5. **Forced sign-outs on iOS** (expired session, trial blocked) don't remove the push token yet. That's an iOS follow-up; just note it in §13.
6. **Deploy order:**
   1. merge #208 and iOS #142;
   2. release the iOS build;
   3. once most phones have updated, `firebase deploy --only firestore:rules,functions`.

   The rules currently deployed are an earlier version, and they still let any manager decide leave for someone with no line manager.

## Done when
- [ ] #208 passes tsc, unit tests, rules tests and a manual check of the preview, then merges into `main-kr70k9` (and on to `main` with #204).
- [ ] Follow-ups 1–4 are decided. Any rule change ships as 1.3.1 or 1.4.0 with a hand-off for iOS.
- [ ] Rules and functions are deployed after the iOS release.
