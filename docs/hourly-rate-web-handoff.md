# Hourly or day rate — web app handoff

Paste the prompt below to the web-app agent. The Firestore contract is the same one the iOS app now reads and writes. A person is on **one** basis. An organisation can mix both.

## Prompt for the web-app agent

Add a pay choice on user setup, manage users, and operative and manager profiles.

Each person is either **Day rate** or **Hourly rate**, never both. Different people in the same organisation can use different choices.

- The organisation day length is `organizations/{orgId}` settings `payrollTimePolicy.standardPaidHours` (hours that count as one day). Use that number everywhere. Do not replace it with `Math.max(standardPaidHours, 8)`. A 7.5-hour organisation day stays 7.5.
- Day rate: pay is `(worked hours / standardPaidHours) × dayRate`. One full organisation day pays the day rate. Half the organisation day pays half the day rate. Show the row in days: `1.00 day × £150.00/day = £150.00` when the org day is 7.5 hours and they worked 7.5. Three organisation days at £350 is `3.00 days × £350.00/day = £1050.00`.
- Hourly rate: pay is `worked hours × hourlyRate`, to the penny. 15 minutes is 0.25 hours. Do not convert those hours into a day count on the same row as the hourly rate. A bad row is `3.00 days`, rate `£20.00`, pay `£480.00`, because 3 × 20 is not 480. The row must be `24.00 hours × £20.00/hr = £480.00` when three 8-hour days were worked at £20. A 15-minute block is `0.25 hours × £20.00/hr = £5.00`. One organisation day of hourly work is `standardPaidHours × hourlyRate` (7.5 × £20 = £150 when the org day is 7.5), while a day-rate person on that same day is still `1.00 day × dayRate`.
- Timesheets, the weekly report, and invoices use this same sum and the same wording. Rate type labels say `Hourly` or `Day` (overtime: `Hourly OT x1.5` or `Day OT x1.5`). Weekly report pay summary columns are Person, Role, Rate Type, Hours / Days, Rate, Pay. The Hours / Days cell is `24.00 hours` or `1.00 day`. The Rate cell is `£20.00/hr` or `£350.00/day`. CSV uses the same headers and the same cell text.
- A booking label such as FULL DAY is the slot name, not the pay quantity. Do not print it beside an hourly rate as if it were the quantity. The labour line on a timesheet and on an invoice is the equation, for example `8.00 hours × £20.00/hr = £160.00`. A clock span such as `07:30–16:00` may sit next to that equation.
- When the basis or the amount changes, append a history row so earlier days keep the old basis. A switch to hourly on Tuesday must not reprice Monday’s day rate.
- PAYE days still show hours and pay £0, same as iOS.
- Do not write both `dayRate` and `hourlyRate` on the same user. Delete the field that does not apply.

## Firestore fields

On `users/{userId}`, the operative roster doc `organizations/{orgId}/operatives/{operativeId}`, the invite doc `invitations/{id}`, and the fallback `organizations/{orgId}/operativeProfiles/{userId}`:

| Field | Type | Meaning |
| --- | --- | --- |
| `payBasis` | string | `"day"` or `"hourly"`. Omit only when no rate is set. |
| `dayRate` | number | Pounds per standard day. Present only when `payBasis` is `"day"`. |
| `hourlyRate` | number | Pounds per hour. Present only when `payBasis` is `"hourly"`. |

`0` is a real zero rate when `payBasis` is set. A legacy operative document with `dayRate: 0`, `hourlyRate: 0`, and no `payBasis` means “not set”. If both amounts are greater than 0 and `payBasis` is missing, treat it as a day rate and ignore `hourlyRate` (old iOS saves copied one number into both fields).

History collection (unchanged path): `organizations/{orgId}/operativeDayRateHistory/{entryId}`

| Field | Type | Meaning |
| --- | --- | --- |
| `dayRate` | number | The amount. Per day or per hour according to `payBasis`. The field name stays `dayRate` so old rows still load. |
| `payBasis` | string | `"day"` or `"hourly"`. Missing means `"day"`. |
| `effectiveAt` | timestamp | First calendar day this amount and basis apply. |
| `userId` | string | Account id, when the person has a login. |
| `operativeId` | string | Roster id, when there is an operative row. |
| `createdAt` | timestamp | When the row was written. |

A person can have two `users` documents with the same email (an invite id and the auth id). Bookings may store either id. Load history for every user id with that email, and for the linked operative id.

Resolve a day from those rows:

- Take rows whose `effectiveAt` calendar day is on or before the booking day.
- If the live profile is hourly, an hourly row covers that day and every later day until a day-rate row falls on a **later calendar day**. A day-rate row later the same day does not cancel the hourly row. Operative saves used to write `payBasis: "day"` even for an hourly amount; do not let that hide hourly.
- Otherwise take the latest row by `effectiveAt`, then `createdAt`.
- Use **that row’s** `payBasis`. If there is no history row and the live profile is hourly, pay hourly. A missing `payBasis` on an old row still means day.

## Pay function (use this, do not invent another)

```javascript
function roundPennies(amount) {
  return Math.round(amount * 100) / 100;
}

function orgDayHours(standardPaidHours) {
  const hours = Number(standardPaidHours);
  return hours > 0 ? hours : 0.01;
}

function payForHours({ payBasis, dayRate, hourlyRate, paidHours, standardDayHours, otMultiplier = 1 }) {
  if (!(paidHours > 0)) return 0;
  const standard = orgDayHours(standardDayHours);
  if (payBasis === "hourly") {
    return roundPennies((hourlyRate ?? 0) * paidHours * otMultiplier);
  }
  return roundPennies((dayRate ?? 0) * (paidHours / standard) * otMultiplier);
}

function money(amount) {
  return `£${(Number(amount) || 0).toFixed(2)}`;
}

function quantityText(quantity, unit) {
  const number = Number(quantity).toFixed(2);
  if (unit === "hours") return Math.abs(quantity - 1) < 0.001 ? `${number} hour` : `${number} hours`;
  return Math.abs(quantity - 1) < 0.001 ? `${number} day` : `${number} days`;
}

function payLineDisplay({ payBasis, paidHours, standardDayHours, rate, pay, isOvertime = false, otMultiplier = null }) {
  const standard = orgDayHours(standardDayHours);
  const hourly = payBasis === "hourly";
  const unit = hourly ? "hours" : "days";
  const quantity = hourly ? paidHours : paidHours / standard;
  const kind = hourly ? "Hourly" : "Day";
  let rateType = kind;
  if (isOvertime) {
    const ot = otMultiplier == null
      ? "OT"
      : Number.isInteger(otMultiplier) ? `OT x${otMultiplier}` : `OT x${Number(otMultiplier).toFixed(1)}`;
    rateType = `${kind} ${ot}`;
  }
  const rateText = rate == null ? "" : `${money(rate)}${hourly ? "/hr" : "/day"}`;
  const qty = quantityText(quantity, unit);
  const equation = rateText ? `${qty} × ${rateText} = ${money(pay)}` : `${qty} = ${money(pay)}`;
  return { rateType, quantityText: qty, rateText, equation, pay: roundPennies(pay) };
}

function exclusiveRates({ dayRate, hourlyRate, payBasis }) {
  const basis = payBasis === "hourly" || payBasis === "day" ? payBasis : null;
  const day = typeof dayRate === "number" ? dayRate : null;
  const hourly = typeof hourlyRate === "number" ? hourlyRate : null;
  if (basis === "hourly") return { payBasis: "hourly", dayRate: null, hourlyRate: hourly };
  if (basis === "day") return { payBasis: "day", dayRate: day, hourlyRate: null };
  if (day != null && day > 0) return { payBasis: "day", dayRate: day, hourlyRate: null };
  if (hourly != null && hourly > 0) return { payBasis: "hourly", dayRate: null, hourlyRate: hourly };
  if (day != null) return { payBasis: "day", dayRate: day, hourlyRate: null };
  return { payBasis: "day", dayRate: null, hourlyRate: null };
}
```

Worked checks the iOS app uses:

- Hourly £20.00 × 0.25 hours displays `0.25 hours × £20.00/hr = £5.00`. Rate type `Hourly`.
- Hourly £20.00 × 24.00 hours (three 8-hour days) displays `24.00 hours × £20.00/hr = £480.00`. Do not display `3.00 days` on that row.
- Hourly £18.00 × 7.25 hours = £130.50.
- Day rate £200.00 × 8 hours with an 8-hour standard day displays `1.00 day × £200.00/day = £200.00`.
- Org day 7.5: day rate £150 for 7.5 hours displays `1.00 day × £150.00/day = £150.00`. Hourly £20 for those same 7.5 hours displays `7.50 hours × £20.00/hr = £150.00`.
- Those two people in one organisation (hourly £130.50 + day £200.00) total £330.50.
- History: £200/day through 5 Oct 2026, then £25/hour from 6 Oct 2026. Monday 5 Oct for 8 hours stays `1.00 day × £200.00/day = £200.00`. Tuesday 6 Oct for 7.25 hours is `7.25 hours × £25.00/hr = £181.25`.

Signed timesheet snapshots stored for the weekly report (`weeklyReportOverride.lines`) include `paidHours`, `days` (hours ÷ org day length), `amount`, and `payBasis` (`"day"` or `"hourly"`). When the weekly report replaces live bookings with a signed timesheet, an hourly line still uses `paidHours` and an hourly rate. A missing `payBasis` on an old snapshot means day rate.

## Sign-off

A person can have two `users` documents with the same email. The timesheet is stored on the id they were signed in as. The line-manager queue must treat those ids as one person.

- Include managers and admins, not only operatives. Hourly and day rate use the same queue. Do not drop a sheet because `payBasis` is `"hourly"`.
- Show the sheet to an assigned line manager when any document for that email has that line manager, the person has signed, and the line manager has not counter-signed.
- Invoice labour uses the same formulas as the timesheet: hourly `8.00 hours × £20.00/hr = £160.00`. Do not invoice that row as a day count.

## Write shape

Day rate person:

```json
{ "payBasis": "day", "dayRate": 200 }
```

Delete `hourlyRate` on update (`FieldValue.delete()`).

Hourly person:

```json
{ "payBasis": "hourly", "hourlyRate": 18.5 }
```

Delete `dayRate` on update.

History row when that hourly rate starts on a chosen day:

```json
{
  "userId": "<users document id>",
  "operativeId": "<operative uuid, if any>",
  "dayRate": 18.5,
  "payBasis": "hourly",
  "effectiveAt": "<timestamp at the start of that calendar day>",
  "createdAt": "<server timestamp>"
}
```
