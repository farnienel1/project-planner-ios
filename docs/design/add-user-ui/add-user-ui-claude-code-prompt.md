# Claude Code prompt: iOS Add New User restyle (UI only)

You're working in the **Project Planner iOS repo**. Restyle the 4-step **Add New User** flow (Account type → User details → Permissions → Review) to match the approved design.

**This is purely visual.** Do not change the following in any way:
- buttons
- steps or flows
- validation
- defaults or templates
- conditional fields
- saving
- the invitation
- permissions
- content

## Files

Put these in the repo at `docs/design/add-user-ui/` before starting:

1. **`add-user-ui-spec.md`** is the source of truth. Section 1, "The UI-only rule", overrides everything else. Section 4 is the field-by-field parity map.
2. **`add-user-ui-reference.html`** is the visual reference, showing all four steps. Open it and match the layout, spacing and colours.
   - Names and values in it are **sample data**.
   - If the HTML and the spec differ, the spec wins.

## Non-negotiables

- **Same actions.** Cancel, Back, Next, Create User, the line manager sheet, the trade picker, the month pickers, every toggle and every expand chevron must call exactly the same code as now.
- **Same rules.** Keep the following identical:
  - Required fields and when Next is enabled.
  - The line-manager rule: a line manager, **or** both Annual Leave Management and Timesheet self-sign.
  - Its message.
  - The Administrator, Manager and Operative templates.
  - Locked permissions.
  - The annual leave defaults.
  - Which fields show for each account type and employment type.
- **Same saved data.** The Firestore user document and the invite must be unchanged.
- **Header user card is display-only.** It shows entered values and writes nothing.
- **Nothing dropped.** Every row in spec §4 must still be present. If you find a field, toggle, text or behaviour in code that isn't in §4, **stop and report it**. Do not drop it or guess where it goes.
- **Don't touch** the web app or any other iOS screen.

## How to work

### Phase 1: Inspect, then stop. No edits.

1. Find the files for the four steps, the line manager sheet, the trade picker and the shared theme.
2. Build an inventory **from the code** of every field, toggle, text, validation rule, conditional and action, per step and per account type and employment type.
3. Compare it with spec §4. Report three lists:
   - what matches;
   - what's in the code but not in the spec;
   - what's in the spec but not in the code.
4. List the files you'll change. They must be presentational only.
5. **Stop and wait for my approval.**

### Phase 2: Build

1. Reuse or add the tokens (spec §2) and shared components:
   - `NavyHeader`
   - `StepTracker`
   - `UserPreviewCard`
   - `SheetContainer`
   - grouped `FormCard`
   - `SegmentedPills`
   - `ToggleRow` (with the "Included" locked state)
   - `ErrorCallout`
   - `BottomActionBar`
2. Restyle the steps in order: Step 1 → 2 → 3 → 4. Commit after each one.
3. Wrap the existing bindings and actions in the new views. Don't rewrite logic.

### Phase 3: Verify and report

1. Work through the spec §5 checklist item by item, giving evidence for each.
2. **Parity test.** Create one Administrator, one Manager (self-employed) and one Operative (PAYE) before and after the change. Compare the saved Firestore documents field by field, and confirm the invites were sent.
3. Provide screenshots of every step for each account type, in light and dark mode, on an iPhone SE and a Pro Max.
4. Report:
   - the files changed;
   - anything you couldn't match;
   - any **Decision needed** items.

Do not claim anything works unless you have tested it.

Begin with Phase 1.
