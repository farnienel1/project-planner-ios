# Project Planner iOS: Scheduling & Booking UI Spec

**Status:** approved design · **Scope:** UI only · **Visual reference:** `booking-ui-reference.html`

This spec restyles seven iOS screens to match the look of the existing Home and Daily overview screens: a navy grid header, a white sheet that slides up, gradient icon tiles and amber overtime stripes.

**Nothing in the data, logic, Firebase reads/writes, permissions or calculations changes.** Every piece of information the current screens show is still shown. Where items are consolidated or moved, Section 4 lists each one: where it was, where it is now, and why.

---

## 1. Ground rules (non-negotiable)

1. **UI only.** Do not change:
   - models, view models, services, Firestore paths, write payloads;
   - calculation code (hours, overtime, break, totals);
   - validation rules, permissions or navigation destinations.
2. **Every field stays.** Each data value and each action in the "Before" column of Section 4 must still be reachable in the new UI. If you find a field or action in code that is not listed here, **stop and report it**. Do not drop it and do not invent a place for it.
3. **Bind, don't recompute.** Bind new layouts to the values the view models already expose.
   - Values marked **(derived)** are simple display arithmetic on values that already exist, such as on-site hours or shift counts.
   - Add a derived value only if it can be calculated in the view layer from existing values without touching business logic. Otherwise omit it and report that you did.
4. **Same actions, same outcomes.** A button that moved or was restyled must call exactly the same code path as before.
5. **Sample data.** Numbers in the reference HTML are sample data copied from the current app. Never hard-code them.
6. **Dark mode and Dynamic Type.**
   - Keep dark mode working. The navy header stays navy. The sheet and cards switch to the dark grouped background colours.
   - Text must scale with Dynamic Type without clipping.

---

## 2. Design tokens

Add these as named colours (Asset Catalog or a `Theme` enum). Do not scatter hex values through views.

| Token | Light | Use |
|---|---|---|
| `headerNavy` | `#0E1B36` + 28pt grid lines at white 4.5% | Header background on all seven screens |
| `headerMuted` | `#93A1BC` | Header labels and secondary text |
| `headerTint` | `#7FA8F5` | Project code in header |
| `headerControl` | white 14% fill | Header pill buttons (Back, Cancel) |
| `sheetBg` | `#F2F4F8` | Sheet background under the header |
| `card` | `#FFFFFF`, border `#E3E8F0` | Cards, list groups, time tiles |
| `fieldBg` | `#F6F8FC` | Inner tiles (time tiles, day cells) |
| `ink` / `inkMuted` | `#0F1B33` / `#64748B` | Body text / secondary text |
| `primary` | gradient `#3B7BF0 → #2559D6` | Primary buttons |
| `primarySolid` | `#2F6FE0` | Toggles, selected dates, links |
| `selectedNavy` | `#0E1B36` | Selected chip / segment / "today" |
| `chipBlue` | bg `#E6EEFC`, text `#17398A` | Status chips |
| `chipAmber` | bg `#FDF1DC`, text `#8A5300` | "Still needed" chips |
| `standard` | `#3B7BF0` | Standard hours in bars and chips |
| `overtime` | stripes `#F5A524` / `#B97810` (header) or `#E39412` (on white) | Overtime |
| `leave` | `#B4632F` | Annual leave |
| `halfDay` | `#3B7BF0` / `#C9D8F8` split | Half day |
| `danger` | gradient `#F2666B → #D92D35` | Warning icon tile, "Heads up" label |
| Tile gradients | blue `#5B8CF0→#2F5FD0`, purple `#8B7CF6→#5B46D6`, green `#34C38F→#12936A`, amber `#FBBF4A→#E08A0B` | Icon tiles, same family as Home quick actions |

**Shape and type**
- Sheet top radius 28.
- Cards 16–18.
- Buttons 14–16, 52pt high for primary.
- Header pills 20.
- Font is SF Pro (the reference uses Inter as a stand-in). Use tabular numbers for all figures.

**Shared components to build once**
- `NavyHeader`
- `SheetContainer`
- `StatRow` (2 or 3 big figures with dividers)
- `DayTimelineBar`
- `TimeTile`
- `ChipRow`
- `BottomActionBar` (chips + primary button)
- `SegmentedPills`
- `IconTile`

---

## 3. Screen-by-screen layout

### 3.1 Scheduling: week view

**Header (navy)**
- Back button (circle).
- Title "Scheduling".
- Client and location label.
- Project type pill.
- Large project code.
- Project name.
- Week switcher card: previous button, "WEEK OF 2 Nov 2026", next button.
- Stat row: **Operatives & managers** count | **Subcontractors** count.

**Sheet**
1. Two action cards:
   - **Book people** (blue tile, opens the existing Operatives & Managers booking flow).
   - **Book a sub** (purple tile, opens the existing Schedule Sub Contractor flow).
2. A week card containing:
   - **Day strip:** 7 cells, each with weekday, date, and a count pill (people booked; "–" when none). Today is filled navy. Weekend cells are muted.
   - **Operatives & managers:** for each person, a name row (avatar, name, role badge such as "Mgr"), then 7 day chips aligned to the strip.
     - Chip states: Standard (blue), Std + OT (blue top showing STD hours, amber striped bottom showing OT hours), OT only (amber stripes), Annual leave (`leave`), Half day (split), empty (dashed outline).
     - Tapping a person or chip does exactly what tapping the booking did before.
   - **Subcontractors:** same row pattern. Empty state: "No subcontractors booked this week" with a **Book** link to the subcontractor flow.
3. Legend: Standard, Std + OT, OT only, Ann. leave, Half day.

**Tab bar:** the existing floating tab bar, unchanged.

### 3.2 Choose subcontractor (Schedule Sub Contractor)

**Header:** Back, title "Schedule subcontractor", green project tile with code + name, then client · client company, then address.

**Sheet**
- "Choose subcontractor" title.
- Search field.
- Horizontal trade filter chips (All trades + every trade). The selected chip is navy.
- A list group where each row shows: initials tile, name, trade, ops-count chip, and a radio button.
- The selected row gets a `primarySolid` radio and a light blue row fill.

**Bottom bar**
- Chips: selection status ("No subcontractor selected" or the selected name) and the days count ("0 days").
- Primary button **Confirm booking**.
- When disabled, the button reads "Choose a subcontractor to confirm" (readable grey, not faded).
- Any later steps in this flow (dates/hours) use the 3.4 patterns.

### 3.3 Schedule booking: in progress

**Header:**
- Back, title.
- Project tile with code + name, then client · project type, then address.
- A **3-step tracker**: Dates, Hours, Operatives. Done steps get a check; the current step has an amber striped bar.

**Sheet**
- Completed steps collapse to summary cards with **Edit** links:
  - Dates: "Tue 17 – Wed 18 Nov", with the count.
  - Hours: shift type, times and paid hours.
- The Operatives empty state keeps the original helper text and an **Add people** button.

**Bottom bar**
- Chips: ✓ dates count, ✓ paid hours per day, and an amber chip for what is missing.
- Disabled button labelled with what is missing ("Add operatives to confirm"), replacing "Select operatives and dates" plus the faded button.

### 3.4 Schedule booking: ready (full scroll)

**Header:**
- The same project block.
- "BOOKING AT A GLANCE": **total paid hours** (derived: per-person paid hours × days, summed) · **shifts** (derived: people × days).
- Stat row: Days | People | Paid hrs/day.

**Sheet**
1. **Dates:**
   - "N selected" chip.
   - Month calendar with previous/next month controls. Today is ringed. Selected dates are filled, and consecutive dates are joined by a light band.
   - Quick chips: **Today, Next 3 days, Next 5 days**. These are the existing Today / 3d / 5d actions.
2. **Hours:**
   - Segmented control **AM | PM | Full day | Custom**.
   - Start/End time tiles. Tapping one opens the existing time picker (same 15-minute steps).
   - A 24h `DayTimelineBar` with a break notch.
   - A green confirmation line: "8.5h paid · 9h on site less 30m unpaid break". This replaces "8.5h paid · 07:00–16:00 → 8.5h · Total 8.5h".
3. **Operatives:**
   - "+ Add people" link.
   - One row per person: avatar, name, role · times, paid hours, and a remove button.
   - Tapping a row opens per-person hours (the existing "set hours per person after they're selected" behaviour).

**Bottom bar**
- Chips: date range, times, people count.
- Primary button **Confirm N shifts** with the total hours on the right.

### 3.5 Edit booking

**Header (navy)**
- **Cancel** pill on the left.
- Title "Edit booking".
- **Delete** as a red bin pill on the right. It must keep the existing delete confirmation; if there is none, show a confirmation sheet before deleting.
- Person row: avatar, name, then date · project code and name.
- "THIS BOOKING AT A GLANCE": **14.5h paid** · **12.5h on site** (derived: end − start − unpaid break).
- Stat row:
  - **Standard hrs**
  - **OT** (amber) with "OT × rate = paid OT"
  - **Unpaid break**
- "THE DAY" card containing:
  - The time range and "· break included".
  - A 24h bar (standard blue, OT amber stripes, break notch).
  - A legend.

**Sheet**
- **Hours:** Start and End time tiles that open the existing time picker.
- **Unpaid break** row: icon tile, title, "30 mins, deducted around midday", toggle.
- **Overtime rate:**
  - Four quick chips: ×1, **×1.5 Org default** (navy when selected), ×2, ×3. Each shows the resulting OT hours.
  - A **More rates** link that opens 3.6.
  - The helper text "Only prices this booking's overtime. Signed timesheets keep their figures."

**Bottom bar:** primary button **Save · 14.5h paid**. It calls the existing save.

**Hours sheet (not drawn):** opened from the Schedule booking flow. Use this same layout:
- Header title "Hours", with Cancel and Save.
- The subtitle "Applies to all selected operatives and dates".
- No person row and no delete.

### 3.6 Overtime rate sheet

- A bottom sheet over a dimmed screen: grabber, amber bolt tile, title, "This booking has Xh of overtime (start – end)", close button.
- **Organisation rate · ×1.5** card at the top: "From Org settings · follows any future change", resulting hours, and a check when selected.
- "OR A CUSTOM RATE FOR THIS BOOKING": a 3-column grid of **every existing option**: ×1, ×1.25, ×1.5, ×1.75, ×2, ×2.25, ×2.5, ×2.75, ×3. Each shows "4h → Xh".
- Info line: signed timesheets keep their figures.
- Primary button "Use ×N · Xh paid". It sets the same value the old menu set.

### 3.7 Unpaid break warning

This replaces the system alert with a bottom sheet:
- Red warning tile.
- "HEADS UP" label.
- Title "This booking runs through lunch".
- Body text: "[start] – [end] covers the unpaid break, so 30 minutes will be deducted. Is that right for this job?"
- A navy mini timeline with the break span highlighted red and labelled "12:30 – 13:00 unpaid".

Actions:

| New button | Does exactly |
|---|---|
| **Pay the full day · 9h** (primary) | Turns the Unpaid break toggle **off**, then runs the existing save. This chains two existing actions. |
| **Keep the break · 8.5h** | The old **Save anyway** |
| **Go back and change the hours** (text) | The old **Go back** |

If chaining two actions is not a pure UI change in this codebase, ship only the last two buttons and report it.

---

## 4. Data and action parity map

Status key:
- **Kept**: same data, restyled.
- **Moved**: same data, new position.
- **Merged**: shown together with other data.
- **Derived**: new display arithmetic on existing values.

### Scheduling

| Before | After | Status |
|---|---|---|
| Back button | Header circle back | Kept |
| Title "Scheduling" | Header title | Kept |
| Project code (C646) | Header, large | Moved |
| Project name | Header under code | Moved |
| Client · city · postcode | Header label above code | Moved |
| Project type tag (DECARBONISATION) | Header pill | Moved |
| Week prev/next + "Week of …" | Header week switcher | Moved |
| "N ops" count | Header stat "Operatives & managers" | Moved |
| "N subs" count | Header stat "Subcontractors" | Moved |
| Operatives & Managers button | "Book people" card | Kept, same action |
| Subcontractors button | "Book a sub" card | Kept, same action |
| Day headers MON–SUN + dates, today ring | Day strip; today filled | Kept |
| PERSON row counts per day | Count pill in each day cell | Merged |
| Operatives & managers rows (avatar, name, role badge) | Name row above day chips | Kept |
| Per-day booking chip "8.5h STD / 6h OT" | Split day chip (STD top, OT bottom) | Kept |
| Empty "No operatives or managers booked this week" | Same text in a dashed empty card | Kept |
| Subcontractors section + empty text | Same, plus a Book link (same action as Book a sub) | Kept |
| Legend (Standard, Std + OT, OT only, Ann. Leave, Half day) | Legend under the card | Kept |
| Tab bar | Unchanged | Kept |

### Choose subcontractor

| Before | After | Status |
|---|---|---|
| Back, title | Header | Kept |
| Project code + name, client, company, address | Header project block | Moved |
| "Choose sub contractor" + search | Sheet title + search | Kept |
| Trade filter chips | Chip row, navy when selected | Kept |
| Row: initials, name, trade, ops count, radio | Same row fields | Kept |
| "No sub contractor selected" + "0 days" | Bottom bar chips | Moved |
| Confirm booking (faded when disabled) | Readable disabled label, then primary | Kept |

### Schedule booking

| Before | After | Status |
|---|---|---|
| Back, title | Header | Kept |
| Project card: code, name, client, type, address | Header project block | Moved |
| "DATES · N selected" | Dates title + chip; also header stat and step tracker | Kept |
| Month calendar + month nav, today ring | Calendar card | Kept |
| Today / 3d / 5d | Today / Next 3 days / Next 5 days | Kept (relabelled) |
| HOURS · AM / PM / FULL DAY / CUSTOM | Segmented control | Kept |
| Start / End | Time tiles that open the existing picker | Kept |
| Timeline bar + break marker | `DayTimelineBar` | Kept |
| "8.5h paid · 07:00–16:00 → 8.5h · Total 8.5h" | Green line; total in header | Merged |
| Operatives helper text + Add people | Empty state (in progress) / list + link (ready) | Kept |
| Per-person hours after selection | Row hours; tap to edit | Kept |
| "Select operatives and dates" status | Bottom bar chips + step tracker | Merged |
| Confirm booking | "Confirm N shifts · total" | Kept, same action |
| *(new)* Total paid, shifts, days, people | Header stats | Derived |

### Edit booking

| Before | After | Status |
|---|---|---|
| Cancel | Header Cancel pill | Kept |
| Save (header) | Bottom "Save · Xh paid" | Moved, same action |
| Title | Header | Kept |
| Person avatar/name, date, project line | Header person row | Moved |
| Start / End wheels | Time tiles that open the existing wheel picker | Kept |
| Timeline (Standard / OT) | Header "THE DAY" bar + legend | Moved |
| Unpaid break toggle + "30 mins deducted around midday" | Break row | Kept |
| Overtime rate menu (Organisation ×1.5, Custom ×1…×3) | Quick chips + full sheet (3.6) | Kept, every option |
| "Prices this booking's overtime hours only…" | Helper text (shortened) and in the sheet | Kept |
| Breakdown: Total | Header "Xh paid" | Moved |
| Breakdown: Standard rate 8.5h · 1× | Header stat "Standard hrs" | Moved |
| Breakdown: Overtime 4h × 1.5 = 6h | Header stat OT "× 1.5 = 6h" | Moved |
| Breakdown: Break −0.5h | Header stat "Unpaid break" | Moved |
| "The break is included within this booking." | "· break included" in THE DAY card | Merged |
| Delete booking | Header bin, with confirmation | Moved, same action |
| *(new)* On-site hours | Header | Derived |

### Unpaid break alert

| Before | After | Status |
|---|---|---|
| Title "Unpaid break" | "HEADS UP" + "This booking runs through lunch" | Kept (reworded) |
| Message text | Body text + mini timeline | Kept (reworded) |
| Go back | "Go back and change the hours" | Kept |
| Save anyway | "Keep the break · 8.5h" | Kept |
| *(new)* Pay the full day | Toggles break off, then saves | Optional (see 3.7) |

---

## 5. Acceptance checklist

- [ ] Every "Before" row in Section 4 is reachable in the new UI.
- [ ] No changes in models, view models, services, Firebase code or calculation code (the diff is limited to views, styles and assets).
- [ ] Same booking saved before and after shows identical figures on Daily overview, Weekly report and Timesheets.
- [ ] Every button triggers the same code path as its old version.
- [ ] Time pickers keep the existing 15-minute steps.
- [ ] Disabled buttons are readable and say what is missing.
- [ ] Dark mode, Dynamic Type (up to XXL) and VoiceOver labels all work. Icon-only buttons have labels.
- [ ] Tested on a small device (iPhone SE) and a large one (Pro Max).
