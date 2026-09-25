# Prompt for the web-app agent — Variations (mirror iOS, close the gaps)

Copy everything below the line into the web-app agent. iOS is already implemented on branch `cursor/ios-variations-1476`. **Do not invent a second data model.** Read that branch first and copy field names, enum raw values, collection paths and notification documents exactly.

---

You are building **Variations** on the **web app**, second. iOS is already live on branch `cursor/ios-variations-1476` in `farnienel1/project-planner-ios`.

Read, in this order:

1. This prompt (wins over the older briefs where they disagree).
2. The iOS files listed below — copy them verbatim, do not re-derive.
3. `cursor-web-variations.md` / `variations-web.html` for screens, density and the tracker UX only.

## Decisions that override the old briefs

1. **There is no `qs` role.** Do not add one. Do not gate anything on a QS permission. Tracker screens are for **admins**. Status copy may still say “submitted by the QS to the client” — that is wording, not a role.
2. **Who sees Variations**
   - **Admins** (super admin, `adminAccess`, or `role == admin`): every project and every small work.
   - **Managers**: only if they are on **that job’s Managers list** (`managerId` / `managerIds` on the project / small work). A manager who can see the Projects catalogue but is not assigned on this job **must not** see the tile / routes.
   - **Operatives: never.** Hide sidebar, routes, drawers, tracker, roll-up. No exception.
3. **Notifications — one write per create, from the platform that created it. No Cloud Function.**
   - If the variation is created on **web**, web writes the notification documents. iOS users then receive **one** notification (existing inbox + push pipeline).
   - If it is created on **iOS** (or later Android), that client writes the same documents. Web must **not** also write, and you must **not** add `onVariationCreated` / `onVariationRenumbered` Cloud Functions. A function plus a client write = two notifications.
   - Use **one** type for every create, including tracker-origin rows: `variation_added`. Do **not** write `variation_from_tracker`.
4. **Spelling is `organizations`**, never `organisations`. Paths, rules, Storage, settings docs — American spelling, matching the rest of this product.
5. iOS Create/Edit project and small works now list assigned managers (add/remove, no “+ N more”). Dirty Save (grey until a change, blue when dirty, dismiss after save) is **Edit** only. Match that manager list on web create/edit if those screens still collapse managers.

## iOS source of truth (read these files)

| What | File |
|---|---|
| Model, enums, codec, numbering | `Project Planner/Models/VariationModels.swift` |
| Trades list | `Project Planner/Core/VariationTrades.swift` |
| Firestore / Storage | `Project Planner/Core/FirebaseBackend+Variations.swift` |
| Visibility | `Project Planner/Core/WorkAccess.swift` (`canAccessVariations`, `isAssignedManager`) |
| Create notification | `Project Planner/Core/NotificationService.swift` (`notifyVariationAdded`) |
| Notification type raw values | `Project Planner/Models/NotificationModel.swift` |
| Rules | `Project Planner/firestore.rules` and `website/firestore.rules` |
| Indexes | `Project Planner/firestore.indexes.json` |

## Firestore contract (copy exactly)

Collections (American spelling):

- `organizations/{orgId}/variations/{variationId}`
- `organizations/{orgId}/variationTrackers/{parentId}`  — document id **is** the parent project/small-work UUID string
- `organizations/{orgId}/settings/variationTrades` — `{ customTrades: string[] }`
- `organizations/{orgId}/settings/variations_{parentId}` — iOS fallback while `variations` collection writes are denied (undeployed rules). Shape: `{ parentId, parentType, organizationId, recordType: "variationLog", items: VariationMap[] | { [variationId]: VariationMap }, updatedAt }`. Web must **read and merge** this with the collection (newer `updatedAt` wins, identity is `id`). Prefer **writing** to `variations/{id}`.
- `organizations/{orgId}/settings/variationItem_{variationId}` — second iOS fallback; one VariationMap per document plus `recordType: "variationItem"`. Merge by `id`.
- Evidence Storage: prefer `organizations/{orgId}/variations/{variationId}/{evidenceId}.{ext}`. iOS also retries `organizations/{orgId}/healthSafety/{parentId}/variationEvidence/...` and `organizations/{orgId}/tasks/{parentId}/files/...` until Storage rules include the variations prefix.

**Identity is `id` (document id). `voNumber` is a display label only.** Never query, deep-link, CSV-key or filename by VO number.

### `Variation` fields (JSON / Firestore)

```
id: string                    // == document id
orgId: string
parentType: "project" | "smallWork"
parentId: string              // UUID string of the project / small work
parentName: string            // "C1042 · 12 High Street" — used in notification body
origin: "app" | "tracker"
voNumber: string              // "VO-014"
sequence: number              // 1-based tracker position
voNumberLocked: boolean
numberHistory: { from, to, at: Timestamp, byUid }[]
heading: string
description: string
status: "open" | "submitted" | "closed"
labour: { id, trade, hours: number }[]
materials: { id, name, quantity: string }[]
evidence: { id, fileName, contentType, sizeBytes, storagePath, downloadURL, uploadedByUid, uploadedAt: Timestamp }[]
totalLabourHours: number      // recompute on every write
materialLineCount: number     // recompute on every write
evidenceCount: number         // recompute on every write
createdByUid, createdByName, createdAt
updatedByUid, updatedAt
statusHistory: { status, byUid, byName, at: Timestamp }[]
submittedAt?: Timestamp
closedAt?: Timestamp
isDeleted: boolean            // soft delete only
```

### `VariationTracker`

```
parentId, parentType
enabled: boolean              // default off; most jobs never turn this on
enabledAt?, enabledByUid?
numberingMode: "lockSubmitted" | "resequenceAll"   // default lockSubmitted
prefix: "VO-"                 // default
padding: 3                    // default
version: number               // increment on every applied renumber
lockedByUid?, lockedByName?, lockedAt?   // 5-minute soft lock
```

### Numbering (do not get this wrong)

- Next VO number is **max numeric part + 1** across **all** variations for that parent, including closed and soft-deleted. **Never reuse a number.**
- Tracker **off** (default): assign next free number at create; never change it. `sequence` is set but unused.
- Turning tracker **on** (web only, one transaction): order existing rows by numeric `voNumber` then `createdAt`; write `sequence` 1…n; lock submitted/closed; **change no `voNumber`**.
- Reorder lives in local state until Apply. Apply is **one writeBatch**: update `sequence`, update `voNumber` only where it changed + append `numberHistory`, increment `version`, release lock. If `version` moved, reject and reload.
- `lockSubmitted`: submitted/closed keep their number and act as anchors. `resequenceAll`: warn if it would renumber submitted/closed.
- Turning tracker off freezes numbers; do not renumber.

### Trades

Ship this list, this order:

Electrician · Approved electrician · Electrician's mate · Plumber · Pipefitter · Ductwork fitter · Ventilation fitter · Sheet metal worker · Gas engineer · Refrigeration engineer · Welder · Insulation engineer · BMS engineer · Fire alarm engineer · Sprinkler fitter · Drainage operative · Commissioning engineer · Testing and inspection · Supervisor · Labourer

Final picker option: **Custom trade…**. Save new names onto `settings/variationTrades.customTrades` so iOS sees them.

### Evidence

- Button copy, exact: **Please upload any supporting evidence here**
- jpg / png / heic / pdf, max 10 files, **20 MB** each
- Upload the file first, then write the `evidence` array entry
- iOS downscales images to 2000px JPEG ~0.7; web should similarly refuse oversized / wrong-type files with a clear message

### Status copy (filter definition block, word for word)

- open: Any variations that have not been submitted, and are still required or have been carried out.
- submitted: Any variations that have been submitted by the QS to the client.
- closed: Any variations that are no longer required.

Dimming: open 100%; submitted ~74% opacity; closed ~54%. Tags keep their colour (amber / green / red).

List empty-state / header line: **Variations add up on a project, so capturing the materials and labour is key.**

## Notifications — exact iOS shape

On **create only** (modal **or** tracker “Add to tracker”), web writes one document per recipient into the **existing** collection:

`organizations/{orgId}/notifications/{uuid}`

Do this in the same create path as the variation write. **Do not add a Cloud Function.**

Recipients: every **active admin** in the org (`isSuperAdmin`, `permissions.adminAccess`, or `role == admin`), **except the creator**. iOS uses the canonical `users/{id}` document id (same id as other in-app notifications). Assigned managers who are not admins do **not** get a push — they see the feature on jobs they are assigned to.

Fields iOS writes (`FirebaseBackend.saveNotification`):

```
organizationId: string
type: "variation_added"
title: "New variation added"
message: "New variation added to {parentName}"
userId: string          // that admin’s user doc id (not null — targeted, not broadcast)
relatedId: string       // parent project / small-work UUID
isRead: false
createdAt: Timestamp
requiresPermission: null
deepLinkUserId: "project" | "smallWork"    // parentType raw value — iOS uses this to open the right catalogue
deepLinkWeekStart: null
```

`parentName` format: `"{jobNumber} · {siteName}"` (job number only / site name only if the other is empty). Same helper as iOS `VariationNumbering.parentName`.

If you apply a tracker renumber, you **may** write a separate in-app `variation_numbers_updated` from that apply path (title/body: `Variation numbers updated on {parentName}`), still **no** Cloud Function, still **not** a second create notification. iOS already displays that type if the document exists. Skip it if you are not sure — do not double-notify creates.

iOS types already in the enum (do not invent others):

- `variation_added`
- `variation_from_tracker` — **do not write this**
- `variation_numbers_updated` — optional, apply path only

## Visibility on web (match iOS)

Reuse the job’s `managerId` / `managerIds` (UUID strings). iOS treats a signed-in manager as assigned when:

- their roster `Manager.id` is in `allAssignedManagerIds`, **or**
- `ProjectManagerPickerSupport.stableManagerId(email:)` matches (deterministic UUID from lowercased email, seed `"pp.manager.{email}"`)

Admins always pass. Operatives always fail. Put this on sidebar, project page, small-works page, `/variations` roll-up, and tracker routes.

## Tracker (web writes; iOS is read-only)

iOS only **reads** `variationTrackers/{parentId}` and shows a read-only list when `enabled == true`. All enable / drag / preview / apply / add-from-tracker behaviour is **web**. Follow `cursor-web-variations.md` section 6 for UX. Copy for the notes panel in that file is required.

Tracker-origin create (`origin: "tracker"`): save as `open`, empty labour/materials, description that site needs to confirm scope and add hours. Still send **one** `variation_added` notification as above. iOS will show the `From tracker` chip from `origin`.

## Routes / screens (from the web brief)

- `/projects/[projectId]/variations` and `/small-works/[smallWorkId]/variations`
- tracker routes for admins only
- optional `/variations` org roll-up for admins
- Sidebar: **Variations** with open-count badge; **Variation tracker** for admins only
- List, new modal, detail drawer, CSV export as in the web brief
- Additive only — do not rename or restyle unrelated pages

## Indexes to deploy

From `Project Planner/firestore.indexes.json`:

- `parentId` ASC, `sequence` ASC
- `parentId` ASC, `status` ASC, `createdAt` DESC
- `orgId` ASC, `status` ASC, `sequence` ASC

iOS currently listens with `parentId ==` only and sorts in memory, so a missing composite index must not break web listeners — still deploy these.

## Rules

iOS already added org-member read/create/update on `variations` and `variationTrackers` (admin-only delete) in both `Project Planner/firestore.rules` and `website/firestore.rules`. **Deploy those rules** or collection creates fail with missing/insufficient permissions. Until they are live, iOS also writes `settings/variations_{parentId}` (covered by existing `settings/{settingId}`). `settings/{settingId}` already covers `variationTrades`. Storage: follow the same org-auth pattern as existing uploads; path prefix `organizations/{orgId}/variations/`. Do not introduce a `qs` check.

## Acceptance — gaps this pass is meant to close

- [ ] Web create (app modal **and** tracker add) writes **exactly one** `variation_added` per admin except the creator. No Cloud Function. iOS users get one banner, not two.
- [ ] iOS create already writes the same documents; web must not echo them.
- [ ] Paths use `organizations` everywhere.
- [ ] No `qs` role. Tracker UI is admin-only. Operatives see nothing. Managers see Variations only on jobs they are assigned to.
- [ ] Field names, enums, denormalised counters and numbering match iOS.
- [ ] Tracker on with existing variations changes **zero** VO numbers.
- [ ] Apply is one batch; iOS list shows `was VO-00x` from `numberHistory` for 7 days.
- [ ] Custom trade saved on web appears in the iOS picker and vice versa.
- [ ] Evidence uploaded on web is viewable on iOS and vice versa.
- [ ] Every pre-existing web page behaves as it did before this branch.
