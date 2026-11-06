# Quick test: 6 Nov

About 15 minutes. Do the web part on your computer and the iPhone part side by side.

## Get the iPhone build

1. On the Mac, open Terminal and run: `cd ~/Developer/project-planner-ios && git pull`
2. Open Xcode and press Run (▶) with your iPhone selected.

The web app updates by itself, so there is nothing to do for it.

## Web

| # | Where | What to check | OK? |
|---|---|---|---|
| 1 | Projects | Under the All / Active / Upcoming / Completed tiles, the search bar sits close, with no big gap before the list. Check Small works the same way. | |
| 2 | Users' Overtime → a person → their request | ✕ is red and ✓ is green on each line. | |
| 3 | Bookings | Book an admin-level user on a job and save. You get no "deleteField" error. | |

## iPhone

| # | Where | What to check | OK? |
|---|---|---|---|
| 4 | More → Settings, at the bottom | It shows "Rules 1.32.3". | |
| 5 | More → Timesheets | It opens as a full page with **Done** at the top left, and Done takes you back. | |
| 6 | Overtime (as a PAYE person) | Each line has ✓ ✕ ⚙. A ticked line fills green, a crossed one goes grey and struck through, and ⚙ opens the change-hours sheet. | |
| 7 | Overtime → Add Expense / Add Price Work | Both open, and they save an item with a photo. | |
| 8 | An overtime, expenses or price work report | It looks like the invoice. Each evidence page is headed by its item. | |
| 9 | Book labour | An operative who has a login but no Operatives-list entry can be booked, with no "No operative profile is linked" message. | |
| 10 | Settings (as admin, if no PAYE payday is set) | The payday banner shows, and tapping it opens Payment runs & timesheets. | |

## If something is wrong

Send a screenshot with the number from the table, for example "6: the cog does nothing".
