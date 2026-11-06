# Project Planner iOS: Add New User UI Spec

**Scope:** the 4-step **Add New User** flow (Account type → User details → Permissions → Review)
**Type:** UI only
**Visual reference:** `add-user-ui-reference.html`

This restyles the flow to match the app's newer screens: Home, Daily overview and the booking screens. That means a navy grid header, a white sheet sliding up, gradient icon tiles, grouped cards and a bottom action bar.

**Nothing about what the flow does changes.** Every field, option, validation, permission default, template, saving, invitation and navigation step stays exactly as it is.

---

## 1. The UI-only rule

If anything else in this spec conflicts with this section, this section wins.

### You MAY change
- Layout, grouping and visual order **within** a step. Field order inside a step may change only where §4 says so.
- Colours, type, spacing, corner radii, icons and control styling. For example:
  - a segmented control instead of two buttons;
  - pill pickers;
  - "Included" badges instead of greyed-out locked toggles.
- Wording of headings and labels where §4 lists it. Helper and validation text stays word for word, except for the light tidy-ups listed in §4.
- Presentational components: header, step tracker, cards, bottom bar.

### You MUST NOT change
- **Steps.** The number of steps, their order, or which fields belong to which step.
- **Behaviour of controls.** Cancel, Back, Next and Create User must call the same code. The line manager picker sheet, trade picker, month pickers, toggles and expand chevrons must all work the same way.
- **Validation.**
  - Required fields.
  - When Next is enabled.
  - The line-manager rule: a line manager **or** both Annual Leave Management and Timesheet self-sign.
  - Its error message.
- **Defaults and templates.**
  - The Administrator template (all access except operative mode, locked modules).
  - Manager defaults (Materials and Site audit locked on).
  - Operative defaults.
  - Annual leave defaults (25 days, Jan → Dec, no carry over, remaining allowance).
- **Conditional logic.** Which fields and toggles appear for each account type and employment type. For example: Trade type for managers and operatives only; Day rate for self-employed only; the annual leave fields hidden when the allowance is off.
- **Saving and invitation.** The user document written to Firebase, its fields and values, the invite email, and what happens after Create User.
- **Permissions.** Who can open this flow.
- **Any other screen**, including Manage Users and the web app.

### Header extras (display only)
The header shows a **live user card**: initials avatar, name, and chips for role, employment type, trade or line manager. On the Review step it shows a 3-figure summary: account type, modules enabled ("4 of 12"), and annual leave days.

These only **display values the user has already entered in this flow**, and they update as fields change. They must not write anything. Before anything is entered they show "New user · Choose an account type to start". The "Modules" count is derived (enabled toggles ÷ total toggles shown). If that count isn't trivially available in the view, omit it.

---

## 2. Design tokens

Reuse the tokens already added for the booking screens (`booking-ui-spec.md` §2) where they exist. Otherwise:

| Token | Value | Use |
|---|---|---|
| `headerNavy` | `#0E1B36` + 28pt grid at white 4.5% | Header |
| `headerMuted` | `#93A1BC` | Header secondary text, inactive step labels |
| `sheetBg` | `#F2F4F8`, top radius 28 | Sheet behind cards |
| `card` | `#FFFFFF`, 1pt `#E3E8F0`, radius 18 | Grouped cards |
| `field` | `#F6F8FC`, 1pt `#E3E8F0`, radius 12–14 | Inputs, pickers |
| `primary` | gradient `#3B7BF0 → #2559D6` | Next / Create User |
| `selected` | `#2F6FE0` | Selected card border and radio, toggles on |
| `segmentOn` | `#0E1B36` | Selected segment (PAYE / Self-employed) |
| `stepCurrent` | amber stripes `#F5A524 / #B97810` | Current step bar |
| `stepDone` | `#3B7BF0` | Completed step bars |
| `included` | bg `#EAF7F1`, text `#0B6B47` | Locked-on permission badge, "Can access" chips |
| `error` | bg `#FDECEC`, text `#9F1C22`, border `#F4B4B7`, icon `#E5484D` | Validation callout |
| Role tiles | Admin blue `#5B8CF0→#2F5FD0`, Manager purple `#8B7CF6→#5B46D6`, Operative amber `#FBBF4A→#E08A0B` | Account type cards and avatar |

Font: SF Pro (the reference uses Inter as a stand-in). Use tabular figures. Touch targets must be at least 44pt.

---

## 3. Shared layout (all steps)

- **Header (navy):**
  - **Cancel** pill on the left. Same action and any confirmation as today.
  - Title "Add new user".
  - "Step N of 4" on the right. This replaces "Step N/4".
  - Live user card (§1).
  - **Step tracker:** 4 bars labelled **Type · Details · Access · Review**. Done steps get a ✓ and a blue bar. The current step has an amber striped bar. This replaces the numbered circles and checkmarks. The tracker is display-only unless steps are tappable today.
- **Sheet:**
  - Step heading. "Permissions" becomes "Access" in the tracker and heading only, and the Review screen still says "Permissions summary".
  - The step's intro text.
  - Grouped cards with small uppercase section labels.
- **Bottom bar:** a white bar holding **Back** (secondary) and **Next / Create User** (primary).
  - On Step 1, Back is disabled, as today.
  - The Next label may name the next step ("Next: details", "Next: review"). This is cosmetic; it calls the same action.
  - **When Next is disabled**, it shows readable grey text saying what's missing (e.g. "Add a line manager to continue"). A red status chip above it repeats the reason. Do not use a faded gradient button.

---

## 4. Step-by-step: field and behaviour parity

### Step 1: Account type

| Before | After | Notes |
|---|---|---|
| Heading "Account Type" + "Choose what kind of account this will be. Super admin is never assigned from here." | Same text | Kept |
| Administrator card: icon, "Full organisation access except operative mode.", radio | Card with blue tile, same text, round check | Same selection |
| Manager card: "Manage teams, schedules and optional modules." | Card with purple tile | Same |
| Operative card: "Schedule, annual leave and qualifications." | Card with amber tile | Same |
| Selected state (purple border + tick) | 2pt blue border, soft shadow, filled blue check | Same state |
| Back (disabled), Next | Bottom bar | Same |

### Step 2: User details

| Before | After | Notes |
|---|---|---|
| "User Details" + "Enter the user's basic information" | Same | Kept |
| First Name, Surname, Email Address, Mobile Number (+ placeholders) | One grouped card, label above value | Same fields, keyboard types, autocapitalisation and validation |
| Employment Type: PAYE / Self-Employed | Segmented control (navy when selected) | Same value |
| Trade type * picker (Electrician ⌃⌄) + "Required for operatives and managers." | Picker row with amber tile; helper text below | Same picker and visibility rules |
| Day rate * (e.g. 250) + "Set a day rate or hourly rate — self-employed people are paid from it." | Field with £ prefix and "per day" suffix; helper text kept | Same field and visibility. The "per day" suffix is cosmetic. If the field also accepts hourly, use the existing unit label instead. |
| VAT number (optional), UTR number (optional) | Two fields side by side | Same |
| Info text "Timesheets follow employment type…" | Blue info box, same text | Kept |
| Line manager(s) + "Required. Timesheets and annual leave requests from this person go to these line manager(s)." + picker row | **LINE MANAGER(S) \*** card with the same text. Shows the selected manager(s) as rows/chips, or a dashed **Choose line manager** button when empty. | Opens the **same** "Line managers" sheet (with Done) |
| Red error "Set a line manager, or turn on both Annual Leave Management and Timesheet self-sign — this person's timesheets and annual leave need approval." | Same message in a red callout **inside the Line manager card**, with a filled red warning triangle. The card border turns red. | Same condition, same wording. The only addition is "in Access" to say where the toggles are. |
| Next disabled (faded) | Readable disabled "Add a line manager to continue" + red chip "Line manager needed" | Same enable rule |

### Step 3: Permissions (shown as "Access")

| Before | After | Notes |
|---|---|---|
| Intro text: Admin "Administrator template — all access except operative mode."; Manager "Choose optional manager access. Anything left off can be enabled later in Manage Users." | Same text, per account type | Kept |
| Toggle rows: Admin Access (admin), Projects, Small Works, Weekly Report, Daily Overview, Sub Contractors, Annual Leave Management, Timesheet self-sign, Operatives, Manage Qualifications, Wholesalers, Materials, Site audit | One **MODULES** card. Each row has an icon tile (blue when on or locked, grey when off), a name with a chevron, and a switch. | **Same rows, same order, same defaults, same visibility per role.** |
| Chevron that expands a description (e.g. Timesheet self-sign: "Sign your own timesheet and generate the invoice without a line manager's signature.") | Same chevron; the description shows under the name when expanded | Same behaviour and text |
| Locked or forced toggles (greyed, tinted) | Green **🔒 Included** badge instead of a switch | Same locked state; still not editable |
| Annual leave allowance toggle + two explanation paragraphs | Card with amber tile, toggle, and both paragraphs in a grey text box | Same toggle; text kept |
| Days per year (25) | Field with "days" suffix | Same |
| Company leave year Jan → Dec + "Runs from the first day of the start month through the last day of the end month (e.g. April → March)." | Two pill buttons Jan → Dec, helper text below (lightly reworded) | Same month pickers |
| Carry unused days into next leave year + explanation | Toggle row, same text | Same |
| "Manually adjust this user's remaining annual leave allowance for this year" + field (25) + "This number will reset to the Days per year figure at the end of your company year." | Title "Remaining allowance this year", with the original sentence as subtitle; field with "days left" suffix; reset note kept | Same field and behaviour |
| Hidden fields when the allowance is off | Same | Same conditional logic |

### Step 4: Review

| Before | After | Notes |
|---|---|---|
| "Review" + "Review before sending the invitation" | Same | Kept |
| Account rows: Type, Name, Email, Employment type, Mobile, Line manager, Trade, Annual leave (days/year, months, carry over) | Same rows in one card, label left and value right | Same rows and conditions. Don't add or remove rows. |
| Permissions summary: Can Access ✓ list / Can't Access ✗ list | **CAN ACCESS · N** green chips; **CAN'T ACCESS · N** grey chips with red ✗ | Same lists, computed the same way |
| Create User | Primary button with envelope icon | Same action and invite. Keep the existing loading/spinner state, restyled. |

### Variants to build that aren't drawn
- **Administrator:** Step 3 with the Admin Access row, all modules shown **Included** except the ones editable today.
- **Operative:** Step 3 shows only what it shows today.
- **PAYE:** Step 2 hides Day rate, as today.
- **Allowance off:** Step 3 hides the leave fields, as today.

---

## 5. Acceptance checklist

- [ ] The diff touches only views, styles, assets and new presentational components. No changes to models, view models' logic, services, Firebase writes, validation, templates or defaults.
- [ ] Every "Before" row in §4 is present and behaves the same, for **all three account types** and **both employment types**.
- [ ] Create a test user of each type before and after the change. The saved Firestore user documents match field for field, apart from IDs and timestamps. The invitation is sent the same way.
- [ ] The line-manager rule blocks and unblocks Next exactly as before, including the "both toggles on" route.
- [ ] Cancel at every step behaves as before.
- [ ] Locked permissions can't be toggled.
- [ ] The header card only displays entered values and writes nothing.
- [ ] Dark mode, Dynamic Type (up to XXL) and VoiceOver work: the switches announce their names and states, and the step tracker reads "Step N of 4".
- [ ] Tested on an iPhone SE and a Pro Max.

---

## 6. Corrections from code (6 Nov)

Phase 1 compared §4 with the code (`Project Planner/Views/AddUserView.swift`, rulebook 1.32.3). Where they differ, **the code is the truth** (owner decision, 6 Nov). The reference HTML is left as drawn; read it with these corrections.

1. **Day rate** is shown for every account type and both employment types. Self-employed (when the adder may set pay): "Day rate \*" with the rulebook's `payRateRequiredMessage`. Otherwise "Day rate (optional)" with "Stored on their user account." (operative) or "Optional. Leave blank if not needed.". §1 "Day rate for self-employed only" and §4 "PAYE: Step 2 hides Day rate" are wrong.
2. **Line-manager message** is the rulebook's `lineManagerRequiredError`, word for word, per level: operative and manager "Set a line manager — this person's timesheets and annual leave need approval."; PAYE admin "Set a line manager, or turn on Annual Leave Management — this person's annual leave needs approval."; self-employed admin "Set a line manager, or turn on both Annual Leave Management and Timesheet self-sign — …". The "both toggles" route exists for admins only. No "in Access" is added.
3. **Manager Step 3** shows the 10 rows the rulebook gives (`permissionToggleRows`): Projects, Small Works, Daily Overview, Sub Contractors, Annual Leave Management, Operatives, Manage Qualifications, Wholesalers, Materials (locked on), Site audit (locked on). Weekly Report and Timesheet self-sign are admin-only since 1.32.0, so the reference's "4 of 12" for a manager reads "N of 10".
4. **"Included" badge** only for rows locked **on**. A row locked **off** (a PAYE admin's Timesheet self-sign) keeps a disabled switch and its note "Not used while PAYE — PAYE has no timesheets.".
5. **Rulebook strings verbatim**: the annual leave allowance copy (including "Manually adjust this user's remaining annual leave allowance for this year") is not retitled, and the leave-year helper is not reworded.
6. **Line manager card** shows the existing summary label ("Not set", a name, "First +N more", "No line manager") as one chip; per-person rows would need a new Core wrapper and are not built.
7. **Disabled Next** reads the rulebook line-manager message when that is what blocks the step, otherwise "Fill in the required fields to continue". No new validation.
8. **Header card** shows "New user · Choose an account type to start" until a first name or surname is typed.
9. **Kept in their current steps (restyled)**: the manager-adding-operative mode (Operative only, "This account is an operative. Super admin is never assigned from here.", "Operative (invited by manager)" on Review), the operative Step 3 intro, the offline message on Review, the success screen, the refused-create messages, and the Review "Day rate" row.
10. **Annual leave defaults** come from the organisation's settings; 25 days, Jan → Dec, no carry over are only the fallback.
