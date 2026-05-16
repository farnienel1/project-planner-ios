# iOS app: Firebase setup in Xcode (step by step)

Use this guide when the app shows a **white screen**, **stuck loading**, or Xcode prints **Firebase is not configured**. Follow the steps **in order**. Do not skip the verification steps at the end.

---

## What this app expects

The code loads Firebase options from a plist file in the **built app bundle**. It looks for files in this order:

1. `GoogleService-Info.plist`
2. `GoogleService-Info 2.plist`

If **neither** file is inside the app bundle, Firebase starts **without** your project keys. Sign-in and Firestore will not work reliably.

The setup code lives in `Project_PlannerApp.swift` (search for `FirebaseStartup`).

---

## Step 1 — Get the plist from Firebase

1. Open [Firebase Console](https://console.firebase.google.com/) and select your project.
2. Click the **gear** next to “Project overview” → **Project settings**.
3. Under **Your apps**, select your **iOS** app (or add an iOS app if none exists).
4. Download **`GoogleService-Info.plist`** to your Mac.

You must use the plist that matches the **same Bundle ID** as your Xcode target (e.g. `farnie.Project-Planner`). If the Bundle ID does not match, Firebase will reject or mis-route traffic.

---

## Step 2 — Put the plist into the Xcode project

1. Open your **Project Planner** Xcode project.
2. In the Project Navigator (left sidebar), decide where Swift files live (often a group named “Project Planner”).
3. **Drag** `GoogleService-Info.plist` from Finder into that group.

When the drop dialog appears:

- Turn **ON** “**Copy items if needed**” (so the file is stored inside the project folder).
- Under **Add to targets**, check **only** the main app target (the one that builds the iOS app, usually named **Project Planner**).
- Click **Finish**.

---

## Step 3 — Use the standard file name (recommended)

**Best:** Rename the file in Xcode to exactly:

`GoogleService-Info.plist`

**Acceptable:** If Xcode created `GoogleService-Info 2.plist`, you can keep it — the app checks that name second. Prefer renaming to `GoogleService-Info.plist` so you only have one canonical file.

---

## Step 4 — Confirm the plist is copied into the app (required)

This step fixes the most common “it works on one Mac but not another” problem.

1. In Xcode, select the **app target** (Project Planner).
2. Open the **Build Phases** tab.
3. Expand **Copy Bundle Resources**.
4. Look in the list for **`GoogleService-Info.plist`** (or `GoogleService-Info 2.plist`).

**If the plist is missing from this list:**

1. Click the **+** button under **Copy Bundle Resources**.
2. Choose your `GoogleService-Info.plist` file.
3. Click **Add**.

---

## Step 5 — Confirm Target Membership (quick check)

1. Click `GoogleService-Info.plist` in the Project Navigator.
2. Open the **File Inspector** (right sidebar, first tab).
3. Under **Target Membership**, the **Project Planner** app target must be **checked**.

If it is unchecked, the file will not be bundled.

---

## Step 6 — Clean build and run

1. Menu: **Product** → **Clean Build Folder** (hold **Option** if you only see “Clean”).
2. Run the app on a simulator or device again.

---

## How you know it worked

With **Debug** builds, the app prints lines like:

- `Firebase configured from GoogleService-Info.plist` (or `GoogleService-Info 2.plist`)
- `Firebase configureIfNeeded — defaultApp exists: true`

That means the plist was **found inside the bundle** and `FirebaseApp.configure(options:)` ran with your real keys.

### If you see this instead (problem)

`No GoogleService-Info plist in bundle`

Then Steps 2–5 were not satisfied: the plist is not in **Copy Bundle Resources** or **Target Membership** is wrong.

---

## About the Firebase messages in the console

| Message | Plain English |
|--------|----------------|
| `I-COR000003` … default Firebase app has not been configured | Sometimes prints **once very early**, before your code runs. **Ignore it** if a few lines later you see **`Firebase configured from …`** and **`defaultApp exists: true`**. |
| `I-SWZ001014` … App Delegate does not conform | Usually fixed by using an `AppDelegate` that subclasses **`NSObject`**. Clean build after pulling latest code. |
| `I-FCM001000` … Remote Notifications proxy enabled | **Information only** — Firebase Cloud Messaging is using automatic hooking. No action unless you choose manual push setup. |

---

## Quick checklist (copy/paste)

- [ ] Downloaded `GoogleService-Info.plist` for the **correct** iOS Bundle ID  
- [ ] Dragged into Xcode with **Copy items if needed**  
- [ ] **Target Membership**: app target checked  
- [ ] **Build Phases → Copy Bundle Resources**: plist listed  
- [ ] **Clean Build Folder**, then Run  
- [ ] Console shows **`Firebase configured from …`** and **`defaultApp exists: true`**

When all boxes are checked, Firebase **initialization** on the device is correct. If the UI still fails, the next place to look is **Authentication**, **Firestore rules**, and **network** — not the plist bundle step.
